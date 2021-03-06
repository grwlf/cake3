{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveDataTypeable #-}
module Development.Cake3.Monad where

import Control.Applicative
import Control.Monad
import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.Trans
import Control.Monad.Loc
import Data.Data
import Data.Typeable
import Data.Monoid
import Data.Maybe
import qualified Data.Map as M
import Data.Map(Map)
import qualified Data.Set as S
import Data.Set(Set)
import qualified Data.String as STR
import Data.List as L hiding (foldl')
import Data.Either
import Data.Foldable (Foldable(..), foldl')
import qualified Data.ByteString.Char8 as BS
import qualified Data.Foldable as F
import qualified Data.Traversable as F
import qualified Data.Text as T
import Development.Cake3.Types
import qualified System.IO as IO
import Text.Printf
import Text.QuasiMake

import Language.Haskell.TH.Quote
import Language.Haskell.TH hiding(unsafe)
import Language.Haskell.Meta (parseExp)

import System.FilePath.Wrapper


type Location = String

-- | MakeState describes the state of the EDSL synthesizers during the
-- the program execution.
data MakeState = MS {
    prebuilds :: Recipe
    -- ^ Prebuild commands. targets/prerequsites of the recipe are ignored,
    -- commands are executed before any target
  , postbuilds :: Recipe
    -- ^ Postbuild commands.
  , prebuildsS :: Set Command
    -- ^ Prebuild commands stored in a Set. Reactive-style-friendly.
  , postbuildsS :: Set Command
    -- ^ Postbuild commands stored in a Set. Reactive-style-friendly.
  , recipes :: Set Recipe
    -- ^ The set of recipes, to be checked and renderd as a Makefile
  , sloc :: Location
    -- ^ Current location. FIXME: fix or remove
  , makeDeps :: Set File
    -- ^ Set of files which the Makefile depends on
  , placement :: [File]
    -- ^ Placement list is the order of targets to be placed in the output file
  , includes :: Set File
    -- ^ Set of files to include in the output file (Makefile specific thing)
  , errors :: String
    -- ^ Errors found so far
  , warnings :: String
    -- ^ Warnings found so far
  , outputFile :: File
    -- ^ Name of the Makefile being generated
  -- , tmpIndex :: Int
    -- ^ Index to build temp names
  , extraClean :: Set File
  -- ^ extra clean files
  }

-- Oh, such a boilerplate
initialMakeState mf = MS defr defr mempty mempty mempty mempty mempty mempty mempty mempty mempty mf mempty

defr = emptyRecipe "<internal>"

getPlacementPos :: Make Int
getPlacementPos = L.length <$> placement <$> get

addPlacement :: Int -> File -> Make ()
addPlacement pos r = modify $ \ms -> ms { placement = r`insertInto`(placement ms) } where
  insertInto x xs = let (h,t) = splitAt pos xs in h ++ (x:t)

addMakeDep :: File -> Make ()
addMakeDep f = modify (\ms -> ms { makeDeps = S.insert f (makeDeps ms) })

tmp_file :: String -> File
tmp_file pfx = (fromFilePath toplevelModule (".cake3" </> ("tmp_"++ pfx )))

prebuild, postbuild, prebuildS, postbuildS :: (MonadMake m) => CommandGen -> m ()

-- | Add prebuild command
prebuild cmdg = liftMake $ do
  s <- get
  pb <- fst <$> runA' (prebuilds s) (shell cmdg)
  put s { prebuilds = pb }

prebuildS cmdg = liftMake $ do
  r <- fst <$> runA' defr (shell cmdg)
  modify (\ms -> ms { prebuildsS = (S.fromList $ rcmd r) `mappend` (prebuildsS ms)})

-- | Add postbuild command
postbuild cmdg = liftMake $ do
  s <- get
  pb <- fst <$> runA' (postbuilds s) (shell cmdg)
  put s { postbuilds = pb }

postbuildS cmdg = liftMake $ do
  r <- fst <$> runA' defr (shell cmdg)
  modify (\ms -> ms { postbuildsS = (S.fromList $ rcmd r) `mappend` (postbuildsS ms)})

-- | Find recipes without targets. Empty result means 'No errors'
checkForEmptyTarget :: (Foldable f) => f Recipe -> String
checkForEmptyTarget rs = foldl' checker mempty rs where
  checker es r | S.null (rtgt r) = es++e
               | otherwise = es where
    e = printf "Error: No target declared for recipe\n\t%s\n" (show r)

-- | Find recipes sharing a target. Empty result means 'No errors'
checkForTargetConflicts :: (Foldable f) => f Recipe -> String
checkForTargetConflicts rs = M.foldlWithKey' checker mempty (groupRecipes rs) where
  checker es k v | S.size v > 1 = es++e
                 | otherwise = es where
    e = printf "Error: Target %s is shared by the following recipes:\n\t%s\n" (show k) (show v)


-- | A Monad providing access to MakeState. TODO: not mention IO here.
class (Monad m) => MonadMake m where
  liftMake :: (Make' IO) a -> m a

newtype Make' m a = Make { unMake :: (StateT MakeState m) a }
  deriving(Monad, Functor, Applicative, MonadState MakeState, MonadIO, MonadFix)

type Make a = Make' IO a

instance MonadMake (Make' IO) where
  liftMake = id

instance (MonadMake m) => MonadMake (A' m) where
  liftMake m = A' (lift (liftMake m))

instance (MonadMake m) => MonadMake (StateT s m) where
  liftMake = lift . liftMake


-- | Evaluate the Make monad @mf@, return MakeState containing the result. Name
-- @mf@ is used for self-referencing recipes.
evalMake :: (Monad m) => File -> Make' m a -> m MakeState
evalMake mf mk = do
  ms <- flip execStateT (initialMakeState mf) (unMake mk)
  return ms {
    errors
      =  checkForEmptyTarget (recipes ms)
      ++ checkForTargetConflicts (recipes ms)
  }

modifyLoc f = modify $ \ms -> ms { sloc = f (sloc ms) }

addRecipe :: Recipe -> Make ()
addRecipe r = modify $ \ms ->
  let rs = recipes ms ; k = rtgt r
  in ms { recipes = (S.insert r (recipes ms)) }

getLoc :: Make String
getLoc = sloc <$> get

-- | Add 'include ...' directive to the final Makefile for each input file.
includeMakefile :: (Foldable t) => t File -> Make ()
includeMakefile fs = foldl' scan (return ()) fs where
  scan a f = do
    modify $ \ms -> ms {includes = S.insert f (includes ms)}
    return ()

instance (Monad m) => MonadLoc (Make' m) where
  withLoc l' (Make um) = Make $ do
    modifyLoc (\l -> l') >> um

-- | 'A' here stands for Action. It is a State monad carrying a Recipe as its
-- state.  Various monadic actions add targets, prerequisites and shell commands
-- to this recipe. After that, @rule@ function records it to the @MakeState@.
-- After the recording, no modification is allowed for this recipe.
newtype A' m a = A' { unA' :: StateT Recipe m a }
  deriving(Monad, Functor, Applicative, MonadState Recipe, MonadIO,MonadFix)

-- | Verison of Action monad with fixed parents
type A a = A' (Make' IO) a

-- | A class of monads providing access to the underlying A monad. It tells
-- Haskell how to do a convertion: given a . (A' m) -> a
-- class (Monad m, Monad a) => MonadAction a m | a -> m where
--   liftAction :: A' m x -> a x

-- instance (Monad m) => MonadAction (A' m) m where
--   liftAction = id

-- | Fill recipe @r using the action @act by running the action monad
runA' :: (Monad m) => Recipe -> A' m a -> m (Recipe, a)
runA' r act = do
  (a,r) <- runStateT (unA' act) r
  return (r,a)

-- | Create an empty recipe, fill it using action @act
runA :: (Monad m)
  => String -- ^ Location string (in the Cakefile.hs)
  -> A' m a -- ^ Recipe builder
  -> m (Recipe, a)
runA loc act = runA' (emptyRecipe loc) act

-- | Version of runA discarding the result of computation
runA_ :: (Monad m) => String -> A' m a -> m Recipe
runA_ loc act = runA loc act >>= return .fst

-- | Get a list of targets added so far
targets :: (Applicative m, Monad m) => A' m (Set File)
targets = rtgt <$> get

-- | Get a list of prerequisites added so far
prerequisites :: (Applicative m, Monad m) => A' m (Set File)
prerequisites = rsrc <$> get

-- | Mark the recipe as 'PHONY' i.e. claim that all it's targets are not real
-- files. Makefile-specific.
markPhony :: (Monad m) => A' m ()
markPhony = modify $ \r -> r { rflags = S.insert Phony (rflags r) }

-- | Adds the phony target for a rule. Typical usage:
--
-- > rule $ do
-- >  phony "clean"
-- >  unsafeShell [cmd|rm $elf $os $d|]
-- >
phony :: (Monad m)
  => String -- ^ A name of phony target
  -> A' m ()
phony name = do
  produce (fromFilePath toplevelModule name :: File)
  markPhony

-- | Mark the recipe as 'INTERMEDIATE' i.e. claim that all it's targets may be
-- removed after the build process. Makefile-specific.
markIntermediate :: (Monad m) => A' m ()
markIntermediate = modify $ \r -> r { rflags = S.insert Intermediate (rflags r) }

-- | Obtain the contents of a File. Note, that this generally means, that
-- Makefile should be regenerated each time the File is changed.
readFileForMake :: (MonadMake m)
  => File -- ^ File to read contents of
  -> m BS.ByteString
readFileForMake f = liftMake (addMakeDep f >> liftIO (BS.readFile (topRel f)))

-- | CommandGen is a recipe-builder packed in the newtype to prevent partial
-- expansion of it's commands
newtype CommandGen' m = CommandGen' { unCommand :: A' m Command }
type CommandGen = CommandGen' (Make' IO)

-- | Pack the command builder into a CommandGen
commandGen :: A Command -> CommandGen
commandGen mcmd = CommandGen' mcmd

-- | Modifie the recipe builder: ignore all the dependencies
ignoreDepends :: (Monad m) => A' m a -> A' m a
ignoreDepends action = do
  r <- get
  a <- action
  modify $ \r' -> r' { rsrc = rsrc r, rvars = rvars r }
  return a

-- | Apply the recipe builder to the current recipe state. Return the list of
-- targets of the current @Recipe@ under construction
shell :: (Monad m)
  => CommandGen' m -- ^ Command builder as returned by cmd quasi-quoter
  -> A' m [File]
shell cmdg = do
  line <- unCommand cmdg
  commands [line]
  r <- get
  return (S.toList (rtgt r))

-- | Version of @shell returning a single file
shell1 :: (Monad m) => CommandGen' m -> A' m File
shell1 = shell >=> (\x -> case x of
  [] -> fail "shell1: Error, no targets defined"
  (f:[]) -> return f
  (f:fs) -> fail "shell1: Error, multiple targets defined")

-- | Version of @shell@ which doesn't track it's dependencies
unsafeShell :: (Monad m) => CommandGen' m -> A' m [File]
unsafeShell cmdg = ignoreDepends (shell cmdg)

-- | Simple wrapper for strings, a target for various typeclass instances.
newtype CakeString = CakeString String
  deriving(Show,Eq,Ord)

-- | An alias to CakeString constructor
string :: String -> CakeString
string = CakeString

-- | Class of things which may be referenced using '\@(expr)' syntax of the
-- quasi-quoted shell expressions.
class (Monad m) => RefOutput m x where
  -- | Register the output item, return it's shell-command representation. Files
  -- are rendered using space protection quotation, variables are wrapped into
  -- $(VAR) syntax, item lists are converted into space-separated lists.
  refOutput :: x -> A' m Command

instance (Monad m) => RefOutput m File where
  refOutput f = do
    modify $ \r -> r { rtgt = f `S.insert` (rtgt r)}
    return_file f

-- FIXME: inbetween will not notice if spaces are already exists
inbetween x mx = (concat`liftM`mx) >>= \l -> return (inbetween' x l) where
  inbetween' x [] = []
  inbetween' x [a] = [a]
  inbetween' x (a:as) = a:x:(inbetween' x as)

spacify l = (CmdStr " ") `inbetween` l

instance (Monad m) => RefOutput m [File] where
  refOutput xs = spacify $ mapM refOutput (xs)

instance (Monad m) => RefOutput m (Set File) where
  refOutput xs = refOutput (S.toList xs)

instance (RefOutput m x) => RefOutput m (Maybe x) where
  refOutput mx = case mx of
    Nothing -> return mempty
    Just x -> refOutput x

instance (RefOutput m File) => RefOutput m (m File) where
  refOutput mx = (A' $ lift mx) >>= refOutput

-- | Class of things which may be referenced using '\$(expr)' syntax of the
-- quasy-quoted shell expressions
class (Monad a) => RefInput a x where
  -- | Register the input item, return it's shell-script representation
  refInput :: x -> a Command

instance (Monad m) => RefInput (A' m) File where
  refInput f = do
    modify $ \r -> r { rsrc = f `S.insert` (rsrc r)}
    return_file f

instance (RefInput a x, MonadMake a) => RefInput a (Make x) where
  refInput mx = liftMake mx >>= refInput

instance (Monad m) => RefInput (A' m) Recipe where
  refInput r = refInput (rtgt r)

instance (RefInput a x) => RefInput a [x] where
  refInput xs = spacify $ mapM refInput xs

instance (RefInput a x) => RefInput a (Set x) where
  refInput xs = refInput (S.toList xs)

instance (MonadIO a, RefInput a x) => RefInput a (IO x) where
  refInput mx = liftIO mx >>= refInput

instance (RefInput a x) => RefInput a (Maybe x) where
  refInput mx =
    case mx of
      Nothing -> return mempty
      Just x -> refInput x

instance (Monad m) => RefInput (A' m) Variable where
  refInput v@(Variable n _) = do
    variables [v]
    return_text $ printf "$(%s)" n

instance (Monad m) => RefInput (A' m) Tool where
  refInput t@(Tool x) = do
    tools [t]
    return_text x

instance (Monad m) => RefInput (A' m) CakeString where
  refInput v@(CakeString s) = do
    return_text s

instance (Monad m) => RefInput (A' m) (CommandGen' m) where
  refInput (CommandGen' a) = a

-- | Add it's argument to the list of dependencies (prerequsites) of a current
-- recipe under construction
depend :: (RefInput a x)
  => x -- ^ File or [File] or (Set File) or other form of dependency.
  -> a ()
depend x = refInput x >> return ()

-- | Declare that current recipe produces item @x@.
produce :: (RefOutput m x)
  => x -- ^ File or [File] or other form of target.
  -> A' m ()
produce x = refOutput x >> return ()

-- | Add variables @vs@ to tracking list of the current recipe
variables :: (Foldable t, Monad m)
  => (t Variable) -- ^ A set of variables to depend the recipe on
  -> A' m ()
variables vs = modify (\r -> r { rvars = foldl' (\a v -> S.insert v a) (rvars r) vs } )

-- | Add tools @ts@ to the tracking list of the current recipe
tools :: (Foldable t, Monad m)
  => (t Tool) -- ^ A set of tools used by this recipe
  -> A' m ()
tools ts = modify (\r -> r { rtools = foldl' (\a v -> S.insert v a) (rtools r) ts } )

-- | Add commands to the list of commands of a current recipe under
-- construction. Warning: this function behaves like unsafeShell i.e. it doesn't
-- analyze the command text
commands :: (Monad m) => [Command] -> A' m ()
commands cmds = modify (\r -> r { rcmd = (rcmd r) ++ cmds } )

-- | Set the recipe's location in the Cakefile.hs
location :: (Monad m) => String -> A' m ()
location l  = modify (\r -> r { rloc = l } )

-- | Set additional flags
flags :: (Monad m) => Set Flag -> A' m ()
flags f = modify (\r -> r { rflags = (rflags r) `mappend` f } )

-- | Has effect of a function @QQ -> CommandGen@ where QQ is a string supporting
-- the following syntax:
--
-- * $(expr) evaluates to expr and adds it to the list of dependencies (prerequsites)
--
-- * \@(expr) evaluates to expr and adds it to the list of targets
--
-- * $$ and \@\@ evaluates to $ and \@
--
-- /Example/
--
-- > [cmd|gcc $flags -o @file|]
--
-- is equivalent to
--
-- >   return $ CommandGen $ do
-- >     s1 <- refInput "gcc "
-- >     s2 <- refInput (flags :: Variable)
-- >     s3 <- refInput " -o "
-- >     s4 <- refOutput (file :: File)
-- >     return (s1 ++ s2 ++ s3 ++ s4)
--
-- Later, this command may be examined or passed to the shell function to apply
-- it to the recipe
--
cmd :: QuasiQuoter
cmd = QuasiQuoter
  { quotePat  = undefined
  , quoteType = undefined
  , quoteDec  = undefined
  , quoteExp = \s -> appE [| \x -> CommandGen' x |] (qqact s)
  } where
    qqact s =
      let chunks = flip map (getChunks (STR.fromString s)) $ \c ->
                     case c of
                       T t -> let t' = T.unpack t in [| return_text t' |]
                       E c t -> case parseExp (T.unpack t) of
                                  Left  e -> error e
                                  Right e -> case c of
                                    '$' -> appE [| refInput |] (return e)
                                    '@' -> appE [| refOutput |] (return e)
                                    _ -> error $ "cmd: unknown quotation modifier " ++ [c]
      in appE [| \l -> L.concat <$> (sequence l) |] (listE chunks)

