{- git repository recovery
 -
 - Copyright 2013 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Git.Repair (
	runRepair,
	runRepairOf,
	successfulRepair,
	cleanCorruptObjects,
	retrieveMissingObjects,
	resetLocalBranches,
	removeTrackingBranches,
	checkIndex,
	missingIndex,
	nukeIndex,
	emptyGoodCommits,
) where

import Common
import Git
import Git.Command
import Git.Objects
import Git.Sha
import Git.Types
import Git.Fsck
import qualified Git.Config as Config
import qualified Git.Construct as Construct
import qualified Git.LsTree as LsTree
import qualified Git.LsFiles as LsFiles
import qualified Git.Ref as Ref
import qualified Git.RefLog as RefLog
import qualified Git.UpdateIndex as UpdateIndex
import qualified Git.Branch as Branch
import Utility.Tmp
import Utility.Rsync
import Utility.FileMode

import qualified Data.Set as S
import qualified Data.ByteString.Lazy as L
import Data.Tuple.Utils

{- Given a set of bad objects found by git fsck, which may not
 - be complete, finds and removes all corrupt objects, and
 - returns a list of missing objects, which need to be
 - found elsewhere to finish recovery.
 -}
cleanCorruptObjects :: FsckResults -> Repo -> IO (Maybe MissingObjects)
cleanCorruptObjects fsckresults r = do
	void $ explodePacks r
	objs <- listLooseObjectShas r
	bad <- findMissing objs r
	void $ removeLoose r $ S.union bad (fromMaybe S.empty fsckresults)
	-- Rather than returning the loose objects that were removed, re-run
	-- fsck. Other missing objects may have been in the packs,
	-- and this way fsck will find them.
	findBroken False r

removeLoose :: Repo -> MissingObjects -> IO Bool
removeLoose r s = do
	fs <- filterM doesFileExist (map (looseObjectFile r) (S.toList s))
	let count = length fs
	if count > 0
		then do
			putStrLn $ unwords
				[ "Removing"
				, show count
				, "corrupt loose objects."
				]
			mapM_ nukeFile fs
			return True
		else return False

explodePacks :: Repo -> IO Bool
explodePacks r = do
	packs <- listPackFiles r
	if null packs
		then return False
		else do
			putStrLn "Unpacking all pack files."
			mapM_ go packs
			return True
  where
	go packfile = withTmpFileIn (localGitDir r) "pack" $ \tmp _ -> do
		moveFile packfile tmp
		nukeFile $ packIdxFile packfile
		allowRead tmp
		-- May fail, if pack file is corrupt.
		void $ tryIO $
			pipeWrite [Param "unpack-objects", Param "-r"] r $ \h ->
				L.hPut h =<< L.readFile tmp

{- Try to retrieve a set of missing objects, from the remotes of a
 - repository. Returns any that could not be retreived.
 -
 - If another clone of the repository exists locally, which might not be a
 - remote of the repo being repaired, its path can be passed as a reference
 - repository.
 
 - Can also be run with Nothing, if it's not known which objects are
 - missing, just that some are. (Ie, fsck failed badly.)
 -}
retrieveMissingObjects :: Maybe MissingObjects -> Maybe FilePath -> Repo -> IO (Maybe MissingObjects)
retrieveMissingObjects missing referencerepo r
	| missing == Just S.empty = return $ Just S.empty
	| otherwise = withTmpDir "tmprepo" $ \tmpdir -> do
		unlessM (boolSystem "git" [Params "init", File tmpdir]) $
			error $ "failed to create temp repository in " ++ tmpdir
		tmpr <- Config.read =<< Construct.fromAbsPath tmpdir
		stillmissing <- pullremotes tmpr (remotes r) fetchrefstags missing
		if stillmissing == Just S.empty
			then return $ Just S.empty
			else pullremotes tmpr (remotes r) fetchallrefs stillmissing
  where
	pullremotes tmpr [] fetchrefs stillmissing = case referencerepo of
		Nothing -> return stillmissing
		Just p -> ifM (fetchfrom p fetchrefs tmpr)
			( do
				void $ explodePacks tmpr
				void $ copyObjects tmpr r
				case stillmissing of
					Nothing -> return $ Just S.empty
					Just s -> Just <$> findMissing (S.toList s) r
			, return stillmissing
			)
	pullremotes tmpr (rmt:rmts) fetchrefs ms
		| ms == Just S.empty = return $ Just S.empty
		| otherwise = do
			putStrLn $ "Trying to recover missing objects from remote " ++ repoDescribe rmt ++ "."
			ifM (fetchfrom (repoLocation rmt) fetchrefs tmpr)
				( do
					void $ explodePacks tmpr
					void $ copyObjects tmpr r
					case ms of
						Nothing -> pullremotes tmpr rmts fetchrefs ms
						Just s -> do
							stillmissing <- findMissing (S.toList s) r
							pullremotes tmpr rmts fetchrefs (Just stillmissing)
				, pullremotes tmpr rmts fetchrefs ms
				)
	fetchfrom fetchurl ps = runBool $
		[ Param "fetch"
		, Param fetchurl
		, Params "--force --update-head-ok --quiet"
		] ++ ps
	-- fetch refs and tags
	fetchrefstags = [ Param "+refs/heads/*:refs/heads/*", Param "--tags"]
	-- Fetch all available refs (more likely to fail,
	-- as the remote may have refs it refuses to send).
	fetchallrefs = [ Param "+*:*" ]

{- Copies all objects from the src repository to the dest repository.
 - This is done using rsync, so it copies all missing objects, and all
 - objects they rely on. -}
copyObjects :: Repo -> Repo -> IO Bool
copyObjects srcr destr = rsync
	[ Param "-qr"
	, File $ addTrailingPathSeparator $ objectsDir srcr
	, File $ addTrailingPathSeparator $ objectsDir destr
	]

{- To deal with missing objects that cannot be recovered, resets any
 - local branches to point to an old commit before the missing
 - objects. Returns all branches that were changed, and deleted.
 -}
resetLocalBranches :: MissingObjects -> GoodCommits -> Repo -> IO ([Branch], [Branch], GoodCommits)
resetLocalBranches missing goodcommits r =
	go [] [] goodcommits =<< filter islocalbranch <$> getAllRefs r
  where
	islocalbranch b = "refs/heads/" `isPrefixOf` show b
	go changed deleted gcs [] = return (changed, deleted, gcs)
	go changed deleted gcs (b:bs) = do
		(mc, gcs') <- findUncorruptedCommit missing gcs b r
		case mc of
			Just c
				| c == b -> go changed deleted gcs' bs
				| otherwise -> do
					reset b c
					go (b:changed) deleted gcs' bs
			Nothing -> do
				nukeBranchRef b r
				go changed (b:deleted) gcs' bs
	reset b c = do
		nukeBranchRef b	r
		void $ runBool
			[ Param "branch"
			, Param (show $ Ref.base b)
			, Param (show c)
			] r

{- To deal with missing objects that cannot be recovered, removes
 - any remote tracking branches that reference them. Returns a list of
 - all removed branches.
 -}
removeTrackingBranches :: MissingObjects -> GoodCommits -> Repo -> IO ([Branch], GoodCommits)
removeTrackingBranches missing goodcommits r =
	go [] goodcommits =<< filter istrackingbranch <$> getAllRefs r
  where
  	istrackingbranch b = "refs/remotes/" `isPrefixOf` show b
	go removed gcs [] = return (removed, gcs)
	go removed gcs (b:bs) = do
		(ok, gcs') <- verifyCommit missing gcs b r
		if ok
			then go removed gcs' bs
			else do
				nukeBranchRef b r
				go (b:removed) gcs' bs

{- Gets all refs, including ones that are corrupt.
 - git show-ref does not output refs to commits that are directly
 - corrupted, so it is not used.
 -
 - Relies on packed refs being exploded before it's called.
 -}
getAllRefs :: Repo -> IO [Ref]
getAllRefs r = map toref <$> dirContentsRecursive refdir
  where
  	refdir = localGitDir r </> "refs"
	toref = Ref . relPathDirToFile (localGitDir r)

explodePackedRefsFile :: Repo -> IO ()
explodePackedRefsFile r = do
	let f = packedRefsFile r
	whenM (doesFileExist f) $ do
		rs <- mapMaybe parsePacked . lines
			<$> catchDefaultIO "" (safeReadFile f)
		forM_ rs makeref
		nukeFile f
  where
	makeref (sha, ref) = do
		let dest = localGitDir r ++ show ref
		createDirectoryIfMissing True (parentDir dest)
		unlessM (doesFileExist dest) $
			writeFile dest (show sha)

packedRefsFile :: Repo -> FilePath
packedRefsFile r = localGitDir r </> "packed-refs"

parsePacked :: String -> Maybe (Sha, Ref)
parsePacked l = case words l of
	(sha:ref:[])
		| isJust (extractSha sha) && Ref.legal True ref ->
			Just (Ref sha, Ref ref)
	_ -> Nothing

{- git-branch -d cannot be used to remove a branch that is directly
 - pointing to a corrupt commit. -}
nukeBranchRef :: Branch -> Repo -> IO ()
nukeBranchRef b r = nukeFile $ localGitDir r </> show b

{- Finds the most recent commit to a branch that does not need any
 - of the missing objects. If the input branch is good as-is, returns it.
 - Otherwise, tries to traverse the commits in the branch to find one
 - that is ok. That might fail, if one of them is corrupt, or if an object
 - at the root of the branch is missing. Finally, looks for an old version
 - of the branch from the reflog.
 -}
findUncorruptedCommit :: MissingObjects -> GoodCommits -> Branch -> Repo -> IO (Maybe Sha, GoodCommits)
findUncorruptedCommit missing goodcommits branch r = do
	(ok, goodcommits') <- verifyCommit missing goodcommits branch r
	if ok
		then return (Just branch, goodcommits')
		else do
			(ls, cleanup) <- pipeNullSplit
				[ Param "log"
				, Param "-z"
				, Param "--format=%H"
				, Param (show branch)
				] r
			let branchshas = catMaybes $ map extractSha ls
			reflogshas <- RefLog.get branch r
			-- XXX Could try a bit harder here, and look
			-- for uncorrupted old commits in branches in the
			-- reflog.
			cleanup `after` findfirst goodcommits (branchshas ++ reflogshas)
  where
	findfirst gcs [] = return (Nothing, gcs)
	findfirst gcs (c:cs) = do
		(ok, gcs') <- verifyCommit missing gcs c r
		if ok
			then return (Just c, gcs')
			else findfirst gcs' cs

{- Verifies tha none of the missing objects in the set are used by
 - the commit. Also adds to a set of commit shas that have been verified to
 - be good, which can be passed into subsequent calls to avoid
 - redundant work when eg, chasing down branches to find the first
 - uncorrupted commit. -}
verifyCommit :: MissingObjects -> GoodCommits -> Sha -> Repo -> IO (Bool, GoodCommits)
verifyCommit missing goodcommits commit r
	| checkGoodCommit commit goodcommits = return (True, goodcommits)
	| otherwise = do
		(ls, cleanup) <- pipeNullSplit
			[ Param "log"
			, Param "-z"
			, Param "--format=%H %T"
			, Param (show commit)
			] r
		let committrees = map parse ls
		if any isNothing committrees || null committrees
			then do
				void cleanup
				return (False, goodcommits)
			else do
				let cts = catMaybes committrees
				ifM (cleanup <&&> check cts)
					( return (True, addGoodCommits (map fst cts) goodcommits)
					, return (False, goodcommits)
					)
  where
	parse l = case words l of
		(commitsha:treesha:[]) -> (,)
			<$> extractSha commitsha
			<*> extractSha treesha
		_ -> Nothing
	check [] = return True
	check ((c, t):rest)
		| checkGoodCommit c goodcommits = return True
		| otherwise = verifyTree missing t r <&&> check rest

{- Verifies that a tree is good, including all trees and blobs
 - referenced by it. -}
verifyTree :: MissingObjects -> Sha -> Repo -> IO Bool
verifyTree missing treesha r
	| S.member treesha missing = return False
	| otherwise = do
		(ls, cleanup) <- pipeNullSplit (LsTree.lsTreeParams treesha) r
		let objshas = map (extractSha . LsTree.sha . LsTree.parseLsTree) ls
		if any isNothing objshas || any (`S.member` missing) (catMaybes objshas)
			then do
				void cleanup
				return False
			-- as long as ls-tree succeeded, we're good
			else cleanup

{- Checks that the index file only refers to objects that are not missing,
 - and is not itself corrupt. Note that a missing index file is not
 - considered a problem (repo may be new). -}
checkIndex :: MissingObjects -> Repo -> IO Bool
checkIndex missing r = do
	(bad, _good, cleanup) <- partitionIndex missing r
	if null bad
		then cleanup
		else do
			void cleanup
			return False

missingIndex :: Repo -> IO Bool
missingIndex r = not <$> doesFileExist (localGitDir r </> "index")

partitionIndex :: MissingObjects -> Repo -> IO ([LsFiles.StagedDetails], [LsFiles.StagedDetails], IO Bool)
partitionIndex missing r = do
	(indexcontents, cleanup) <- LsFiles.stagedDetails [repoPath r] r
	let (bad, good) = partition ismissing indexcontents
	return (bad, good, cleanup)
  where
	getblob (_file, Just sha, Just _mode) = Just sha
	getblob _ = Nothing
	ismissing = maybe False (`S.member` missing) . getblob

{- Rewrites the index file, removing from it any files whose blobs are
 - missing. Returns the list of affected files. -}
rewriteIndex :: MissingObjects -> Repo -> IO [FilePath]
rewriteIndex missing r
	| repoIsLocalBare r = return []
	| otherwise = do
		(bad, good, cleanup) <- partitionIndex missing r
		unless (null bad) $ do
			nukeIndex r
			UpdateIndex.streamUpdateIndex r
				=<< (catMaybes <$> mapM reinject good)
		void cleanup
		return $ map fst3 bad
  where
	reinject (file, Just sha, Just mode) = case toBlobType mode of
		Nothing -> return Nothing
		Just blobtype -> Just <$>
			UpdateIndex.stageFile sha blobtype file r
	reinject _ = return Nothing

nukeIndex :: Repo -> IO ()
nukeIndex r = nukeFile (localGitDir r </> "index")

newtype GoodCommits = GoodCommits (S.Set Sha)

emptyGoodCommits :: GoodCommits
emptyGoodCommits = GoodCommits S.empty

checkGoodCommit :: Sha -> GoodCommits -> Bool
checkGoodCommit sha (GoodCommits s) = S.member sha s

addGoodCommits :: [Sha] -> GoodCommits -> GoodCommits
addGoodCommits shas (GoodCommits s) = GoodCommits $
	S.union s (S.fromList shas)

displayList :: [String] -> String -> IO ()
displayList items header
	| null items = return ()
	| otherwise = do
		putStrLn header
		putStr $ unlines $ map (\i -> "\t" ++ i) truncateditems
  where
  	numitems = length items
	truncateditems
		| numitems > 10 = take 10 items ++ ["(and " ++ show (numitems - 10) ++ " more)"]
		| otherwise = items

{- Fix problems that would prevent repair from working at all
 -
 - A missing or corrupt .git/HEAD makes git not treat the repository as a
 - git repo. If there is a git repo in a parent directory, it may move up
 - the tree and use that one instead. So, cannot use `git show-ref HEAD` to
 - test it.
 -
 - Explode the packed refs file, to simplify dealing with refs, and because
 - fsck can complain about bad refs in it.
 -}
preRepair :: Repo -> IO ()
preRepair g = do
	unlessM (validhead <$> catchDefaultIO "" (safeReadFile headfile)) $ do
		nukeFile headfile
		writeFile headfile "ref: refs/heads/master"
	explodePackedRefsFile g
  where
	headfile = localGitDir g </> "HEAD"
	validhead s = "ref: refs/" `isPrefixOf` s || isJust (extractSha s)

{- Put it all together. -}
runRepair :: Bool -> Repo -> IO (Bool, MissingObjects, [Branch])
runRepair forced g = do
	preRepair g
	putStrLn "Running git fsck ..."
	fsckresult <- findBroken False g
	if foundBroken fsckresult
		then runRepair' fsckresult forced Nothing g
		else do
			putStrLn "No problems found."
			return (True, S.empty, [])

runRepairOf :: FsckResults -> Bool -> Maybe FilePath -> Repo -> IO (Bool, MissingObjects, [Branch])
runRepairOf fsckresult forced referencerepo g = do
	preRepair g
	runRepair' fsckresult forced referencerepo g

runRepair' :: FsckResults -> Bool -> Maybe FilePath -> Repo -> IO (Bool, MissingObjects, [Branch])
runRepair' fsckresult forced referencerepo g = do
	missing <- cleanCorruptObjects fsckresult g
	stillmissing <- retrieveMissingObjects missing referencerepo g
	case stillmissing of
		Just s
			| S.null s -> if repoIsLocalBare g
				then successfulfinish S.empty []
				else ifM (checkIndex S.empty g)
					( successfulfinish s []
					, do
						putStrLn "No missing objects found, but the index file is corrupt!"
						if forced
							then corruptedindex
							else needforce S.empty
					)
			| otherwise -> if forced
				then ifM (checkIndex s g)
					( continuerepairs s
					, corruptedindex
					)
				else do
					putStrLn $ unwords
						[ show (S.size s)
						, "missing objects could not be recovered!"
						]
					unsuccessfulfinish s
		Nothing
			| forced -> ifM (pure (repoIsLocalBare g) <||> checkIndex S.empty g)
				( do
					missing' <- cleanCorruptObjects Nothing g
					case missing' of
						Nothing -> return (False, S.empty, [])
						Just stillmissing' -> continuerepairs stillmissing'
				, corruptedindex
				)
			| otherwise -> unsuccessfulfinish S.empty
  where
	continuerepairs stillmissing = do
		(remotebranches, goodcommits) <- removeTrackingBranches stillmissing emptyGoodCommits g
		unless (null remotebranches) $
			putStrLn $ unwords
				[ "Removed"
				, show (length remotebranches)
				, "remote tracking branches that referred to missing objects."
				]
		(resetbranches, deletedbranches, _) <- resetLocalBranches stillmissing goodcommits g
		displayList (map show resetbranches)
			"Reset these local branches to old versions before the missing objects were committed:"
		displayList (map show deletedbranches)
			"Deleted these local branches, which could not be recovered due to missing objects:"
		deindexedfiles <- rewriteIndex stillmissing g
		displayList deindexedfiles
			"Removed these missing files from the index. You should look at what files are present in your working tree and git add them back to the index when appropriate."
		let modifiedbranches = resetbranches ++ deletedbranches
		if null resetbranches && null deletedbranches
			then successfulfinish stillmissing modifiedbranches
			else do
				unless (repoIsLocalBare g) $ do
					mcurr <- Branch.currentUnsafe g
					case mcurr of
						Nothing -> return ()
						Just curr -> when (any (== curr) modifiedbranches) $ do
							putStrLn $ unwords
								[ "You currently have"
								, show curr
								, "checked out. You may have staged changes in the index that can be committed to recover the lost state of this branch!"
								]
				putStrLn "Successfully recovered repository!"
				putStrLn "Please carefully check that the changes mentioned above are ok.."
				return (True, stillmissing, modifiedbranches)
	
	corruptedindex = do
		nukeIndex g
		-- The corrupted index can prevent fsck from finding other
		-- problems, so re-run repair.
		fsckresult' <- findBroken False g
		result <- runRepairOf fsckresult' forced referencerepo g
		putStrLn "Removed the corrupted index file. You should look at what files are present in your working tree and git add them back to the index when appropriate."
		return result

	successfulfinish stillmissing modifiedbranches = do
		mapM_ putStrLn
			[ "Successfully recovered repository!"
			, "You should run \"git fsck\" to make sure, but it looks like everything was recovered ok."
			]
		return (True, stillmissing, modifiedbranches)
	unsuccessfulfinish stillmissing = do
		if repoIsLocalBare g
			then do
				putStrLn "If you have a clone of this bare repository, you should add it as a remote of this repository, and retry."
				putStrLn "If there are no clones of this repository, you can instead retry with the --force parameter to force recovery to a possibly usable state."
				return (False, stillmissing, [])
			else needforce stillmissing
	needforce stillmissing = do
		putStrLn "To force a recovery to a usable state, retry with the --force parameter."
		return (False, stillmissing, [])

successfulRepair :: (Bool, MissingObjects, [Branch]) -> Bool
successfulRepair = fst3

safeReadFile :: FilePath -> IO String
safeReadFile f = do
	allowRead f
	readFileStrictAnyEncoding f
