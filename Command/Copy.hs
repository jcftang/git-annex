{- git-annex command
 -
 - Copyright 2010 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Command.Copy where

import Command
import qualified Command.Move

-- A copy is just a move that does not delete the source file.
seek :: [CommandSeek]
seek = [withFilesInGit $ Command.Move.start False]
