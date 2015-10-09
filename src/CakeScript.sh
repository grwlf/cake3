#!/bin/sh

die() { echo "$@" >&2 ; exit 1 ; }
err() { echo "$@" >&2 ; }

CAKEURL=https://github.com/grwlf/cake3
ARGS="$@"

# Return relative path from canonical absolute dir path $1 to canonical
# absolute dir path $2 ($1 and/or $2 may end with one or no "/").
# Does only need POSIX shell builtins (no external command)
relPath () {
    local common path up
    common=${1%/} path=${2%/}/
    while test "${path#"$common"/}" = "$path"; do
        common=${common%/*} up=../$up
    done
    path=$up${path#"$common"/}; path=${path%/}; printf %s "${path:-.}"
}

cakepath() {
cat <<EOF
-- This file was autogenerated by cake3.
-- $CAKEURL

{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE QuasiQuotes #-}
module ${1}_P(

  -- functions
  file,
  cakefiles,
  selfUpdate,
  writeDefaultMakefiles,
  filterDirectoryContentsRecursive,

  -- tools
  cake3,
  cakegen,
  urembed,
  caketools,
  cwd
  ) where

import Control.Monad.Trans
import Control.Monad.State
import Development.Cake3
import Development.Cake3.Monad
import Development.Cake3.Ext.UrWeb
import Development.Cake3.Utils.Slice
import Development.Cake3.Utils.Find

t2m :: FilePath
t2m = "`relPath "$TOP" "$2"`"

m2t :: FilePath
m2t = "`relPath "$2" "$TOP"`"

pl = ModuleLocation t2m m2t

file :: String -> File
file x = file' pl x

cwd :: CakeString
cwd = string t2m

projectroot :: FilePath
projectroot = "$TOP"

moduleroot :: FilePath
moduleroot = "$2"

cakefiles :: [File]
cakefiles =
  let rl = ModuleLocation t2m m2t in
  case "$2" of
    "$TOP" -> map (file' rl) ($3)
    _ -> error "cakefiles are defined for top-level cakefile only"

cakegen = tool "./Cakegen"
cake3 = tool "cake3"

selfUpdate :: Make [File]
selfUpdate = do
  makefile <- outputFile <$> get
  (_,cg) <- rule' $ do
    depend cakefiles
    produce (file "Cakegen")
    shell [cmd|\$(cake3) $ARGS|]
  (_,f) <- rule' $ do
    depend cg
    produce makefile
    shell [cmd|\$(cakegen)|]
  return f

caketools = [urembed,cake3,cakegen]

writeDefaultMakefiles m = writeSliced (file "Makefile.dev") [(file "Makefile", caketools)] (selfUpdate >> m)

EOF
}

caketemplate() {
cat <<"EOF"
{-# LANGUAGE QuasiQuotes, OverloadedStrings #-}
module Cakefile where
-- TODO: write the template
EOF
}

ARGS_PASS=""
GHCI=n
GHC_EXTS="-XFlexibleInstances -XTypeSynonymInstances -XQuasiQuotes"
CAKEDIR=""

while test -n "$1" ; do
  case "$1" in
    --help|-h|help)
      err "Cake3 the Makefile generator"
      err "$CAKEURL"
      err "Usage: cake3 [--help|-h] [-C DIR] [init] args"
      err "cake3 init"
      err "    - Create the default Cakefile.hs"
      err "cake3 <args>"
      err "    - Compile the ./Cakegen and run it"
      err ""
      err "-C DIR   scan the tree for Cakefiles starting from DIR"
      err ""
      err "Arguments <args> are passed to the ./Cakgegen as is"
      exit 1;
      ;;
    init)
      test -f Cakefile.hs &&
        die "Cakefile.hs already exists"
      caketemplate > Cakefile.hs
      echo "Cakefile.hs has been created"
      exit 0;
      ;;
    -C) CAKEDIR="$2"; shift
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
    find -L . $CAKEDIR -mindepth $l -maxdepth $l -type f '(' -name 'Cake*\.hs' -or -name 'Cake*\.lhs' \
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
  *) fdir_abs=`realpath $(pwd)/$fdir` ;;
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

