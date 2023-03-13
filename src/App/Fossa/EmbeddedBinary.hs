{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module App.Fossa.EmbeddedBinary (
  BinaryPaths,
  ThemisIndex,
  ThemisBins (..),
  toPath,
  withWigginsBinary,
  withThemisAndIndex,
  withBerkeleyBinary,
  allBins,
  dumpEmbeddedBinary,
) where

-- The intent with these embedded binaries is that the build system will replace the files with
-- built binaries of the appropriate architecture.
-- The below functions are expected to warn since the vendor-bins directory is typically populated in CI.
-- If you wish to run these on your local system, populate these binaries via `vendor_download.sh`.
--
-- Each binary is in its own module because GHC runs out of stack space when embedding files.
-- By splitting them into their own modules GHC doesn't have to try to load them all at once.
--
-- A better solution might be to use 'xxd -i' to generate a C file with the data and then access it via FFI. 
-- This should be more resistant to memory issues.
-- It seems memory issues with file-embed were addressed once before: https://github.com/snoyberg/file-embed/issues/24.
-- The fix for that should be working for our code though, which suggests this is something different.
-- In the future we should find a workaround.
import App.Fossa.EmbeddedBinary.BerkeleyDB (embeddedBinaryBerkeleyDB)
import App.Fossa.EmbeddedBinary.Themis (embeddedBinaryThemis, embeddedBinaryThemisIndex)
import App.Fossa.EmbeddedBinary.Wiggins (embeddedBinaryWiggins)

import Codec.Compression.Lzma qualified as Lzma
import Control.Effect.Exception (bracket)
import Control.Effect.Lift (Has, Lift, sendIO)
import Data.ByteString (ByteString, writeFile)
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (traverse_)
import Data.String.Conversion (toLazy, toString)
import Data.Tagged (Tagged, applyTag, unTag)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Path (
  Abs,
  Dir,
  File,
  Path,
  Rel,
  fromAbsFile,
  mkRelDir,
  mkRelFile,
  parent,
  parseRelDir,
  (</>),
 )
import Path.IO (
  Permissions (executable),
  ensureDir,
  getPermissions,
  getTempDir,
  removeDirRecur,
  setPermissions,
 )
import Prelude hiding (writeFile)

data PackagedBinary
  = Wiggins
  | Themis
  | ThemisIndex
  | BerkeleyDB
  deriving (Show, Eq, Enum, Bounded)

allBins :: [PackagedBinary]
allBins = enumFromTo minBound maxBound

data BinaryPaths = BinaryPaths
  { binaryPathContainer :: Path Abs Dir
  , binaryFilePath :: Path Rel File
  }
  deriving (Eq, Ord, Show)

data ThemisBinary

data ThemisIndex

data ThemisBins = ThemisBins
  { themisBinaryPaths :: Tagged ThemisBinary BinaryPaths
  , indexBinaryPaths :: Tagged ThemisIndex BinaryPaths
  }

toPath :: BinaryPaths -> Path Abs File
toPath BinaryPaths{..} = binaryPathContainer </> binaryFilePath

cleanupThemisBins :: Has (Lift IO) sig m => ThemisBins -> m ()
cleanupThemisBins (ThemisBins a b) = traverse_ cleanupExtractedBinaries [unTag a, unTag b]

withThemisAndIndex :: Has (Lift IO) sig m => (ThemisBins -> m c) -> m c
withThemisAndIndex = bracket extractThemisFiles cleanupThemisBins

-- When running Themis we always need both the themis-cli and the decompressed index.gob
extractThemisFiles :: Has (Lift IO) sig m => m ThemisBins
extractThemisFiles = do
  themisBin <- extractEmbeddedBinary Themis
  let themisActual = applyTag @ThemisBinary themisBin
  -- TODO: refactor into `extractXZippedBinary ThemisIndex`
  -- decompress index.gob.xz binary and write it to disk
  container <- sendIO extractDir
  let decompressedThemisIndex =
        BinaryPaths
          { binaryPathContainer = container
          , binaryFilePath = $(mkRelFile "index.gob")
          }
  _ <- sendIO $ ensureDir $ parent $ toPath decompressedThemisIndex
  _ <- sendIO $ BL.writeFile (toString $ toPath decompressedThemisIndex) (Lzma.decompress $ toLazy embeddedBinaryThemisIndex)
  pure $ ThemisBins themisActual $ applyTag @ThemisIndex decompressedThemisIndex

withWigginsBinary ::
  ( Has (Lift IO) sig m
  ) =>
  (BinaryPaths -> m c) ->
  m c
withWigginsBinary = withEmbeddedBinary Wiggins

withBerkeleyBinary ::
  ( Has (Lift IO) sig m
  ) =>
  (BinaryPaths -> m c) ->
  m c
withBerkeleyBinary = withEmbeddedBinary BerkeleyDB

withEmbeddedBinary ::
  ( Has (Lift IO) sig m
  ) =>
  PackagedBinary ->
  (BinaryPaths -> m c) ->
  m c
withEmbeddedBinary bin = bracket (extractEmbeddedBinary bin) cleanupExtractedBinaries

cleanupExtractedBinaries :: (Has (Lift IO) sig m) => BinaryPaths -> m ()
cleanupExtractedBinaries (BinaryPaths binPath _) = sendIO $ removeDirRecur binPath

extractEmbeddedBinary :: (Has (Lift IO) sig m) => PackagedBinary -> m BinaryPaths
extractEmbeddedBinary bin = do
  container <- sendIO extractDir
  -- Determine paths to which we should write the binaries
  let binPath = extractedPath bin
  -- Write the binary
  sendIO $ writeBinary (container </> binPath) bin
  -- Return the paths
  pure (BinaryPaths container binPath)

dumpEmbeddedBinary :: Has (Lift IO) sig m => Path Abs Dir -> PackagedBinary -> m ()
dumpEmbeddedBinary dir bin = writeBinary path bin
  where
    path = dir </> extractedPath bin

writeBinary :: (Has (Lift IO) sig m) => Path Abs File -> PackagedBinary -> m ()
writeBinary dest bin = sendIO . writeExecutable dest $ case bin of
  Wiggins -> embeddedBinaryWiggins
  Themis -> embeddedBinaryThemis
  ThemisIndex -> embeddedBinaryThemisIndex
  BerkeleyDB -> embeddedBinaryBerkeleyDB

writeExecutable :: Path Abs File -> ByteString -> IO ()
writeExecutable path content = do
  ensureDir $ parent path
  writeFile (fromAbsFile path) content
  makeExecutable path

extractedPath :: PackagedBinary -> Path Rel File
extractedPath bin = case bin of
  -- Rename wiggins upon local extraction so that we can provide a better status line to users during the VSI strategy.
  -- Users don't know what "wiggins" is, but they explicitly enable the VSI plugin, so this is more intuitive.
  Wiggins -> $(mkRelFile "vsi-plugin")
  Themis -> $(mkRelFile "themis-cli")
  ThemisIndex -> $(mkRelFile "index.gob.xz")
  BerkeleyDB -> $(mkRelFile "berkeleydb-plugin")

-- | Extract to @$TMP/fossa-vendor/<timestamp>
-- We used to extract everything to @$TMP/fossa-vendor@, but there's a subtle issue with that.
-- Cleanup is just removing the directory where the file resides, which is fine unless there's
-- more than one active extracted file.  Cleanup could potentially kill both while one is in use.
-- Extracting to another subdir means that the cleanup only cleans the timestamp subdir.
-- The only downside is that we never cleanup the fossa-vendor directory, which is not an issue,
-- since it should be empty by the time we finish cleanup.  The tempfile cleaner on the system
-- should pick it up anyway.
extractDir :: Has (Lift IO) sig m => m (Path Abs Dir)
extractDir = do
  wd <- sendIO getTempDir
  -- Get some positive "random" number, in this case a timestamp
  -- at microsecond resolution.  Does not need to be exact, just
  -- unique enough.
  ts <- show @Int . abs . floor . (* 1_000_000) <$> sendIO getPOSIXTime
  subDir <- sendIO $ parseRelDir ts
  pure (wd </> $(mkRelDir "fossa-vendor") </> subDir)

makeExecutable :: Path Abs File -> IO ()
makeExecutable path = do
  p <- getPermissions path
  setPermissions path (p{executable = True})

