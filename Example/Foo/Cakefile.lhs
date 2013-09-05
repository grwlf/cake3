This is a Makefile-like Haskell program describing the build rule for Foo
project.

> {-# LANGUAGE QuasiQuotes #-}

Due to convention, name of module should match name of file (without .hs). Cake3
script will copy all the cakefiles into one temporary dir, so names should
differ from each other and match filenames exactly. That is we have CakeLib.hs
in ./lib, not Cakefile.hs.

> module Cakefile where

Import tha Cake3 library

> import Development.Cake3

Import paths. This file will be generated by the cake3 script.

> import Cakefile_P (file,cakefiles)

Foo uses a library with it's own cakefile in ./lib. So we import it as usual
haskell module

> import qualified CakeLib as L

Now for the main part: Lets begin with a variable named CFLAGS having a value of
'-O0 -g3'.

> cflags = makevar "CFLAGS" "-O0 -g3"

Another possibility - a variable which has a name but is set elsewhere in the
environment.

> shellvar = extvar "SHELL" -- normally, will expand to something like /bin/bash

Next we define a list of files (this particular list has one element) of type
[File]. file function translate Cakefile-relative path to the project's top dir
relative path. In our case it just turns main.c to ./main.c. For the ./lib
library, lib.c will be translates into ./lib/lib.c if we run cake3 in the
top level. file function is defined in Cakefile_P.hs

> cfiles = [ file "main.c"]

Now it is time to define rules. Rules are lists of Aliases. each alias
associates target with it's recipe.

    type Rule = [Alias]

    newtype Alias = Alias (File, Make Recipe)


To create a rule, one have to call rule (or phony) function which takes list of
targets and an action as it's arguments

    rule :: [File] -> A () -> [Alias]

Actions can be easily defined using [shell| ... |] syntax This trick saves user
from writing boilerplate code like

    elf = rule (file "main.elf") $ do
      dst_ <- ref dst
      cflags_ <- ref cflags
      objs_ <- ref objs_
      make ("gcc -o " ++ dst_ ++ " " ++ cfalgs_ ++ " " ++ objs_ )

Using quotes, we can write just

    elf = rule (file "main.elf") $ do
      shell [cmd|gcc -o $dst $cflags $objs|]

Here, $dst reference is a function defined in Development.Cake3. It expands into
space-separated list of names of targets

> sound = "Yuupee"
>
> elf = rule [file "main.elf"] $ do
>   shell [cmd| echo "SHELL is $shellvar" |] -- refer to shell
>   shell [cmd| gcc -o $dst $allofiles |] -- refer to dst (aka $@) and *.o
>   shell [cmd| echo $sound |]            -- refer to sound

Now .o files: define a rule for each of them

> ofiles = do 
>   c <- cfiles
>   rule [c .= "o"] $ do
>     shell [cmd| gcc -I lib -c $cflags -o $dst $c |]

Remember, Foo project also uses a library. Lets bring together all the objects.
Just refer to the ofiles defined in CakeLib.

> allofiles = ofiles ++ (L.ofiles cflags)

Ok. We also need clean and all rules.  Clean is a special rule in a sence that
it doesn't use dependencies or variable guards. Usually, clean just should do
what user tolds it to do. Thus, we use unsafe to disable dependency checks. That
way, cake will generate

    .PHONY:clean
    clean:
        rm ./main.elf ; rm GUARD_* ; .. and so on

instead of

    .PHONY:clean
    clean: ./main.elf ./main.o $(GUARD1)
        rm ./main.elf ; rm GUARD_* ; .. and so on

> clean :: [Alias]
> clean = phony "clean" $ unsafe $ do
>     shell [cmd| rm $elf ; rm GUARD_* ; rm $allofiles ; rm $cakegen |]

Rule named 'all' is just an alias for elf

> the_all = phony "all" $ do
>   depend elf

And one more thing: lets add a self-update rules to make. We say, that Makefile
depend on ./Cakegen and ./Cakegen depend on cakefiles of current project.
Normally, that is not the whole story because Makefile actually depend on
directory structure of a project and some other things. Still, it is better than
nothing.

> cakegen = rule [file "Cakegen" ] $ do
>   depend cakefiles
>   shell [cmd| cake3 |]

> selfupdate = rule [makefile] $ do
>   shell [cmd| $cakegen > $dst |]

Finally, default Haskell main function collects all required rules and prints the
Makefile's contents on a standard output. User should not list all the rules,
they only need to list top-level rules, he/she wants to see in the Makefile.

> main = do
>   runMake [the_all, clean, selfupdate] >>= putStrLn . toMake

