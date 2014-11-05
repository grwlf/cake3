#!/bin/sh

die() { echo "$@" >&2 ; exit 1 ; }
err() { echo "$@" >&2 ; }

CAKEURL=https://github.com/grwlf/cake3

cakepath() {
cat <<EOF
-- This file was autogenerated by cake3.
-- $CAKEURL

{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE QuasiQuotes #-}
module ${1}_P(file, cakefiles, selfUpdate,filterDirectoryContentsRecursive) where

import Control.Monad.Trans
import Control.Monad.State
import Development.Cake3
import Development.Cake3.Monad
import Development.Cake3.Utils.Find
import GHC.Exts (IsString(..))

pl = ProjectLocation projectroot moduleroot

file :: String -> File
file x = file' pl x

-- instance IsString File where
--   fromString = file

projectroot :: FilePath
projectroot = "$TOP"

moduleroot :: FilePath
moduleroot = "$2"

cakefiles :: [File]
cakefiles = 
  let rl = ProjectLocation projectroot projectroot in
  case "$2" of
    "$TOP" -> map (file' rl) ($3)
    _ -> error "cakefiles are defined for top-level cake only"

selfUpdate :: Make [File]
selfUpdate = do
  makefile <- outputFile <$> get
  (_,cg) <- rule2 $ do
    depend cakefiles
    produce (file "Cakegen")
    shell [cmd|cake3|]
  (_,f) <- rule2 $ do
    produce makefile
    shell [cmd|\$cg|]
  return f

filterDirectoryContentsRecursive :: (MonadIO m) => [String] -> m [File]
filterDirectoryContentsRecursive exts = liftM (filterExts exts) (getDirectoryContentsRecursive (file "."))

EOF
}

caketemplate() {
cat <<"EOF"
{-# LANGUAGE QuasiQuotes, OverloadedStrings #-}
module Cakefile where

import Development.Cake3
import Cakefile_P (file,projectroot)


main = writeMake "Makefile" $ do

  cs <- filterDirectoryContentsRecursive [".c"]

  d <- rule $ do
    shell [cmd|gcc -M @cfiles -MF %(file "depend.mk")|]

  os <- forM cs $ \c -> do
    rule $ do
      shell [cmd| gcc -c $(extvar "CFLAGS") -o %(c.="o") @c |]

  elf <- rule $ do
    shell [cmd| gcc -o %(file "main.elf") @os |]

  rule $ do
    phony "all"
    depend elf

  includeMakefile d

EOF
}

ARGS_PASS=""
GHCI=n
GHC_EXTS="-XFlexibleInstances -XTypeSynonymInstances -XOverloadedStrings -XQuasiQuotes"

while test -n "$1" ; do
  case "$1" in
    --help|-h|help) 
      err "Cake3 the Makefile generator"
      err "$CAKEURL"
      err "Usage: cake3 [--help|-h] [init] args"
      err "cake3 init"
      err "    - Create the default Cakefile.hs"
      err "cake3 <args>"
      err "    - Compile the ./Cakegen and run it. Args are passed as is."
      err ""
      err "Other arguments are passed to the ./Cakgegen as is"
      exit 1;
      ;;
    init)
      test -f Cakefile.hs &&
        die "Cakefile.hs already exists"
      caketemplate > Cakefile.hs
      echo "Cakefile.hs has been created"
      exit 0;
      ;;
    ghci)
      GHCI=y
      ;;
    *)
      ARGS_PASS="$ARGS_PASS $1"
      ;;
  esac
  shift
done

CWD=`pwd`
T=`mktemp -d`

cakes() {
  for l in `seq 1 1 10`; do
    find -L -mindepth $l -maxdepth $l -type f '(' -name 'Cake*\.hs' -or -name 'Cake*\.lhs' \
       -or -name '*Cake\.hs' -or -name '*Cake\.lhs' ')' \
       -and -not -name '*_P.hs' | sort
  done \
  | grep -v '^\.[a-zA-Z].*'
}

OIFS=$IFS
IFS=$'\n'
CAKES=`cakes`
CAKELIST="[]"
for f in $CAKES ; do
  CAKELIST="\"$f\" : $CAKELIST" 
done

MAIN_=
MAIN=
TOP=
for f in $CAKES ; do
  fname_=$(basename "$f")
  tgt=$T/$fname_
  fname=$(echo "$fname_" | sed 's/\.l\?hs//')
  pname="${fname}_P.hs"
  fdir=$(dirname "$f")
  case $fdir in
  .) fdir_abs=$(pwd) ;;
  *) fdir_abs=$(pwd)/$fdir ;;
  esac

  if test "$fdir" = "." ; then
    if test -n "$MAIN" ; then
      die 'More than one Cake* file in current dir'
    fi
    MAIN=$fname
    MAIN_=$fname_
    TOP=$fdir_abs
  fi

  if test -f "$tgt" ; then
    err "Warning: duplicate file name, ignoring $f."
    continue
  fi

  cp "$f" "$tgt" ||
    die "Couldn't cp $f $tgt"

  if cat "$f" | grep -q "import.*${fname}_P" ; then
    err "Creating $fdir/${pname}"
    cakepath "$fname" "$fdir_abs" "$CAKELIST" > "$fdir/${pname}"

    cp "$fdir/${pname}" "$T/${pname}" ||
      die -n "cp $fdir/${pname} $T/${pname} failed"
  else
    err "Warning: ${pname} is not required by $f"
  fi
done

if test -z "$MAIN" ; then
  die "No Cake* file exist in the current directory. Consider running \`cake3 --help'."
fi

IFS=$OIFS

(
set -e
cd $T
case $GHCI in
  n) ghc --make "$MAIN_" $GHC_EXTS -main-is "$MAIN" -o Cakegen ;;
  y) exec ghci -main-is "$MAIN" $GHC_EXTS ;;
esac

cp -t "$CWD" Cakegen
) &&
./Cakegen $ARGS_PASS

