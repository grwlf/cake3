Cake3
=====

Cake3 is a EDSL for building Makefiles, written in Haskell. With cake3,
developer can write their build logic in Haskell, obtain clean and safe Makefile
and distribute it among the non-Haskell-aware users. Currenly, GNU Make is
the only backend supported.

The Goals
---------

Make is a build tool which was created more than 20 yesrs ago. It has a number
of versions and dialects. Basic Makefiles are really easy to write and
understand.  Unfortunately, it is hard to write real-world scale set of rules
correctly due to tricky syntax and lots of pitfails. As of today, Make has
automatic, declarative and imperative variables, builtin rules, pattern-rules,
double-colon rules, C-style ifdefs (which doesn't work well with declarative
variables) and lots of other strange things. Nevertheless, it is still widely
used as a de-facto standard tool which everyone has access to.

The goals of Cake3 are to help the developer to:

  * Stop overusing Make by writing complex logic in make-language
  * Still have a correct Makefile which could be distributed among the users
  * Take a bit of Haskell practice :)

Installation
------------

From Hackage:
  
    $ cabal install cake3


From the Github:

  1. Install [Haskell Platform](http://www.haskell.org/platform/)

  2. Install dependencies
    
         $ cabal install haskell-src-meta monadloc QuasiText

  3. Build the thirdcake from Github

         $ git clone http://github.com/grwlf/cake3
         $ cd cake3
         $ cabal configure && cabal install

Usage
-----

  1. Create the Cakefile.hs in the root dir of your project

        $ cake3 init

  2. Edit Cakefile.hs, fill it with rules or other logic you need 

        $ vim Cakefile.hs

  3. Debug your generator with

        $ cake3 ghci
        Prelude> :lo Cakefile.hs 

  3. Build the Makefile with cake3

        $ cake3

  4. Run GNU make as usual

How does it work
----------------

Cake3 allows user to write Cakefile.hs in plain Haskell to define rules, targets
and other stuff as usual. After that, `cake3` compiles it into ./Cakegen
application which builds your Makefile (ghc is required for that). GNU Make
knows how to do the rest.

### Example

Here is the example of simple Cakefile.hs:

    module Cakefile where

    import Development.Cake3
    import Cakefile_P

    main = writeMake "Makefile" $ do

      selfUpdate

      cs <- filterDirectoryContentsRecursive [".c"]

      d <- rule $ do
        shell [cmd|gcc -M $cs -MF @(file "depend.mk")|]

      os <- forM cs $ \c -> do
        rule $ do
          shell [cmd| gcc -c $(extvar "CFLAGS") -o @(c.="o") $c |]

      elf <- rule $ do
        shell [cmd| gcc -o @(file "main.elf") $os |]

      rule $ do
        phony "clean"
        unsafeShell [cmd|rm $elf $os $d|]

      rule $ do
        phony "all"
        depend elf

      includeMakefile d


  * Cakefile\_P is an autogenerated module. It defines `file :: String -> File`
    function plus some others.
  * All action is performed inside Make monad
  * Main building blocks - `rule` functions - build Makefile rules one-to-one.
    The prerequisites are computed based on it's actions.
  * All actions live in Action monad (`A` Monad). `shell` and `unsafeShell` is
    the most important of them. 
  * Quasy-quotation is used to simplify the shell code. `[cmd||]` takes a string
    as an argument. It's syntax includes:
    *  $name untiquotes hasell expressions `name` of type File, Variable plus few
       others. They define a prerequisites of a rule
    *  @name untiquotes hasell expressions `name` of type File. They define
       rule's targets
    *  complex expressions are also supported with $(foo bar) and @(bar baz).
  * Rules appears in the Makefile in the reversed order. Normally, you want
    'all' rule to be at the bottom.


Features and limitations
------------------------

Thirdcake follows Autoconf's path in a sence that it builds the program may do
some checks and tests and generates the Makefile. In the same time, the idea of
this EDSL is to move as much logic as possible in the final Makefile, to drop
the cake3 dependency at the build time.

Of cause, it is possible up to some degree. For example, Cake3 doe not provide a
way to scan the project tree with Make's wildcards. But it is possible and may
be implemented in future.

Still, some common patterns are supported so I hope that users would call
resulting Makefiles safe and robust enough for, say, package maintainers.

### Features

  * *Allows spaces inside the filenames.*
  
    Everyone knows that Makefiles don't like spaces in filenames. Cake3
    carefully inserts '\ ' to make make happy.

  * *Rebuilds a rule when variable changes.*
  
    Consider following antipattern:

        # You often write rules like this, don't you?
        out : in
             foo $(FLAGS) -o $@ $^

    Unfortunately, changes in FLAGS don't lead to rebuilding of out.
    Hardly-trackable bugs may appear if one part of a project was built with one
    set of optimisation flags and another part was build with another set by
    mistake.

    Thirdcake implements the makevar checksum
    [pattern](http://stackoverflow.com/a/17830736/1133157) from StackOverflow to
    detect changes in variables and rebuild targets when nessesary.

        rule $ do
          shell [cmd|foo $(extvar "FLAGS") -o @out $in |]

    will rebuild `out` on FLAGS change
 
  * *Supports rules with more than one target.*
    
    It is not that simple to write a rule which has more than one target. Really,
        
        out1 out2 : in1 in2
            foo in1 in2 -o out1 -o out2

    is not corret. Read this [Automake
    article](http://www.gnu.org/software/automake/manual/html_node/Multiple-Outputs.html#Multiple-Outputs)
    if you are surprised. Thirdcake implements [.INTERMEDIATE
    pattern](http://stackoverflow.com/a/10609434/1133157) to deal with this
    problem so `rule` like this

        rule $ do
          shell [cmd|foo $in1 $in2 -o @out1 -o @out2 |]

    will always notice inputs changes and rebuild both outputs

  * *Supports global prebuild\postbuild actions*

    Common human-made Makefile with prebuild commands would support them for one
    rule, typically, "all". Other targets often stay uncovered. Cake3 makes sure
    that actions are executed for any target you call.

  * *Lets user organize build hierarchy.*
  
    Say, we have a project A with subproject L. L has it's own Makefile and we
    want to re-use it from our global A/Makefile. Make provides only two ways of
    doing that. We could either include L/Makefile or call $(MAKE) -C L. First
    solution is a pain because merging two Makefiles together is generally a
    hard work. Second approach is OK, but only if we don't need to pass
    additional paramters or depend on a specific rule from L.

    Thirdcake's approach in this case is a compromise: since it employs
    Haskell's module system, it is possible to write:

        -- Project/lib/CakeLib.hs
        import CakeLib_P.hs
        librule = do
          rule $ do
            shell [cmd|build a lib|]

        -- Project/Cakefile.hs
        import Cakefile_P.hs
        import CakeLib.hs 
        -- ^ note the absence of lib folder here. cake3 will copy all Cake*hs to
        --   the temp dir, then build them there.

        all = do
          lib <- librule
          rule $ do
            shell [cmd|build an app with $lib |]

    A/Cakefile.hs and do whatever you want to. Resulting makefiles will always
    be monolitic.

### Limitations

#### Make syntax

  * Make is not able to detect directory content chages. For example, user has
    to rerun the ./Cakegen if they add/remove a source file. I plan to automate
    this kind of checks. so it is on my TODO list.
  * ifdef/endif instructions is not supported generally. User has to move this
    logic in Haskell for now. Also on my TODO list
  * Cake3 doesn't check the contents of Makefile variables. It is user's
    responsibility to keep them safe.
  * Variables as targets is not supported. Implement this logic in Haskell for
    now.

#### General

  * Resulting Makefile is actually a GNUMakefile. GNU extensions (shell function
    and others) are needed to make various tricks to work. Also, posix
    environment with coreututils package is required. So, Linux, Probably Mac,
    Probably Windows+Cygwin.
  * All Cakefiles across the project tree should have unique names in order to
    be copied. Duplicates are found, the first one is used

Random implementation details
-----------------------------

  1. User writes a cakefile (./Cake\*.hs) describing the rules. Refer to
     Example/GHC/Cakefile.hs. Note, that different cakefiles should have
     different names even if they are in different directories due to GHC import
     restrictions. This way user can import one cakefile from another, as if
     they were in the same directory. Actually, cake3 copies all cakefiles into
     one temporary directory and compiles them there. Note that cake3 calls ghc
     having several common haskell extentions enabled.

  2. Cake3 copies all Cake\*.hs files from your project tree into temporary dir
     and compiles them with GHC (or calls GHCi). Before that, it creates a
     ./Cake\*_P.hs pathfile containing information about paths. The most
     important is _files_ function which translates relative _filename_ into
     _"." </> path_to_subproject </> filename_.

  3. Cake3 uses relative paths only for the final Makefile.

  4. Cake3 uses it's own representation of files (File). Many filepath functions
     (takeDirectory, takeBaseName, dropExtensions, </>, etc) are defined for
     them. See System.FilePath.Wrapper.hs. FileLike typeclass makes it possible
     to use them with plain FilePath as well.

