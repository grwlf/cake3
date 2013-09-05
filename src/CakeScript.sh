#!/bin/sh

die() { echo "$@" >&2 ; exit 1 ; }
err() { echo "$@" >&2 ; }

CAKEURL=https://github.com/grwlf/cake3

cakepath() {
cat <<EOF
-- This file was autogenerated by cake3.
-- $CAKEURL

module ${1}_P(file,cakefiles) where

import Prelude hiding (FilePath)
import Development.Cake3
import Filesystem.Path.CurrentOS as P

file :: String -> FilePath
file x = file' "$TOP" "$2" x

cakefiles :: [FilePath]
cakefiles = case "$2" of
              "$TOP" -> map (file' "$TOP" "$TOP") \$ $3
              _ -> error "cakefiles are defined for top-level cake only"

EOF
}

caketemplate() {
cat <<"EOF"
{-# OPTIONS_GHC -F -pgmF MonadLoc #-}
{-# LANGUAGE OverloadedStrings, QuasiQuotes #-}

module Cakefile where

import Control.Monad.Loc
import Development.Cake3

import Cakefile_P (file, cakefiles)

elf = rule [file "main.elf"] $ do
    [shell| echo "Your commands go here" ; exit 1 ; |]

all = do
  phony "all" $ do
    depend elf

-- Self-update rules
cakegen = rule [file "Cakegen" ] $ do
  depend cakefiles
  [shell| cake3 |]

selfupdate = rule [file "Makefile"] $ do
  [shell| $cakegen > $dst |]

main = do
  runMake [Cakefile.all, elf, selfupdate] >>= putStrLn . toMake

EOF
}

while test -n "$1" ; do
  case "$1" in
    --help|-h|help) 
      err "Cake3 the Makefile generator help"
      err "$CAKEURL"
      err "Usage: cake3 [--help|-h] [init]"
      err "cake3 init"
      err "    - Create default Cakefile.hs"
      err "cake3"
      err "    - Build the Makefile"
      exit 1;
      ;;
    init)
      test -f Cakefile.hs &&
        die "Cakefile.hs already exists"
      caketemplate > Cakefile.hs
      echo "Cakefile.hs has been created"
      exit 0;
      ;;
  esac
  shift
done

CWD=`pwd`
T=`mktemp -d`

cakes() {
  find -type f '(' -name 'Cake*\.hs' -or -name 'Cake*\.lhs' \
               -or -name '*Cake\.hs' -or -name '*Cake\.lhs' ')' \
               -and -not -name '*_P.hs' \
    | grep -v '^\.[a-zA-Z].*'
}

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
    die "More than one file named '${fname}.hs' in the filetree"
  fi

  cp "$f" "$tgt" ||
    die "cp $f $tgt failed. Duplicate names?"

  if cat "$f" | grep -q "import.*${fname}_P" ; then
    echo "Creating $fdir/${pname}" >&2
    cakepath "$fname" "$fdir_abs" "$CAKELIST" > "$fdir/${pname}"

    cp "$fdir/${pname}" "$T/${pname}" ||
      die -n "cp $fdir/${pname} $T/${pname} failed"
  else
    echo "Skipping creating $fdir/${pname}" >&2
  fi
done

if test -z "$MAIN" ; then
  die "No Cake* file exist in the current directory. Consider running \`cake3 --help'."
fi

(
set -e
cd $T
ghc --make "$MAIN_" -main-is "$MAIN" -o Cakegen
cp -t "$CWD" Cakegen
) &&

./Cakegen > Makefile  && echo "Makefile created" >&2

