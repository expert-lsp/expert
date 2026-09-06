# Changelog

## [0.2.0](https://github.com/expert-lsp/expert/compare/v0.1.0...v0.2.0) (2026-09-06)


### Features

* add compileOnType configuration ([#819](https://github.com/expert-lsp/expert/issues/819)) ([faffb9f](https://github.com/expert-lsp/expert/commit/faffb9fad921b7dd441edf5ef0bcf84c4e59de18)), closes [#795](https://github.com/expert-lsp/expert/issues/795)
* add configuration to autofetch dependencies ([#750](https://github.com/expert-lsp/expert/issues/750)) ([ee5aee2](https://github.com/expert-lsp/expert/commit/ee5aee2dc6467beb09643a7308ef063024649e43))
* add hex intelligence ([#570](https://github.com/expert-lsp/expert/issues/570)) ([ace9d05](https://github.com/expert-lsp/expert/commit/ace9d050c863129bd8fd0b48ee705d9926ac40b8))
* allow multiple index writers with SQLite ([#683](https://github.com/expert-lsp/expert/issues/683)) ([02b0080](https://github.com/expert-lsp/expert/commit/02b0080886bd974a18889609e91db2d66bfbf44d))
* allow setting Elixir source directory ([#568](https://github.com/expert-lsp/expert/issues/568)) ([6e623d2](https://github.com/expert-lsp/expert/commit/6e623d2f50a7618d59cf92b7592e2e026cbcfa15))
* configure toolchain paths ([#682](https://github.com/expert-lsp/expert/issues/682)) ([b3f039e](https://github.com/expert-lsp/expert/commit/b3f039ec024081929bc9776afe8a024fc48ced30))
* defer code action execution ([#761](https://github.com/expert-lsp/expert/issues/761)) ([86fc69d](https://github.com/expert-lsp/expert/commit/86fc69d268f27789240e3ab1172d3ae45b452814))
* **engine:** expand engine builder error output ([#659](https://github.com/expert-lsp/expert/issues/659)) ([0cebb78](https://github.com/expert-lsp/expert/commit/0cebb7861dd4d45f0dd4111884ff2c577e100118))
* **engine:** find definition for functions defined by macro ([#759](https://github.com/expert-lsp/expert/issues/759)) ([fde8d85](https://github.com/expert-lsp/expert/commit/fde8d853899a974aec446f57199777f941e517f7))
* **engine:** index defmacro/defmacrop definitions ([#554](https://github.com/expert-lsp/expert/issues/554)) ([ab84d7a](https://github.com/expert-lsp/expert/commit/ab84d7ace9e563b8615745028b4780b2ed965901))
* **expert:** allow setting file log level via configuration ([#563](https://github.com/expert-lsp/expert/issues/563)) ([eeb6628](https://github.com/expert-lsp/expert/commit/eeb6628bc43e6a99470454522a9a5bef227f0cdc)), closes [#541](https://github.com/expert-lsp/expert/issues/541)
* **expert:** autodetect Elixir source ([#779](https://github.com/expert-lsp/expert/issues/779)) ([b2458b0](https://github.com/expert-lsp/expert/commit/b2458b037a88a92145a00d328df0502ec76b4afa))
* **expert:** fold anonymous functions ([#881](https://github.com/expert-lsp/expert/issues/881)) ([2f2fbf5](https://github.com/expert-lsp/expert/commit/2f2fbf57d0782e7b7e161c51c67509bc00992f57))
* **expert:** fold consecutive comment lines ([#743](https://github.com/expert-lsp/expert/issues/743)) ([63dc1f3](https://github.com/expert-lsp/expert/commit/63dc1f31807d4a87b7d8ae842f1e942dacfe839f))
* **expert:** support folding ranges ([#649](https://github.com/expert-lsp/expert/issues/649)) ([684d19a](https://github.com/expert-lsp/expert/commit/684d19a4d56d7d4b7150bb99f2930462ffb98a50))
* fall back to other arities in go-to-definition when exact arity has no result ([#728](https://github.com/expert-lsp/expert/issues/728)) ([65ceece](https://github.com/expert-lsp/expert/commit/65ceece06fbc68699a08b361bc4bfe811a56eedf))
* make on-the-fly engine builds work offline ([#739](https://github.com/expert-lsp/expert/issues/739)) ([9e8c774](https://github.com/expert-lsp/expert/commit/9e8c77499a632087475310e8ba3796463a04213a))
* use compiler tracers for project indexing ([#705](https://github.com/expert-lsp/expert/issues/705)) ([ea1f104](https://github.com/expert-lsp/expert/commit/ea1f1048c8fe95c5f69474c103fed2781fa3c7c2))
* use compiler tracers to index definitions ([#799](https://github.com/expert-lsp/expert/issues/799)) ([c95f6e6](https://github.com/expert-lsp/expert/commit/c95f6e6601ced19e1b74297d3db2b746dc11ff7b))


### Bug Fixes

* bring back remote shell ([#584](https://github.com/expert-lsp/expert/issues/584)) ([f85c7a5](https://github.com/expert-lsp/expert/commit/f85c7a5c17bebc7d605ddaca2f8b3a6f0d62c74e))
* build a single engine for multiple projects using the same toolchain versions ([#509](https://github.com/expert-lsp/expert/issues/509)) ([7501e68](https://github.com/expert-lsp/expert/commit/7501e68347bf58424e917b8230f1c7601839633b))
* bump spitfire to v0.3.13 ([#714](https://github.com/expert-lsp/expert/issues/714)) ([899149e](https://github.com/expert-lsp/expert/commit/899149e00d45dcef9e980182b52dc06042d3cb72))
* clear stale diagnostics as you type ([#878](https://github.com/expert-lsp/expert/issues/878)) ([2afc03c](https://github.com/expert-lsp/expert/commit/2afc03ce8ce4c37fe93a369ec39d4140859e4b48))
* compile the engine with MIX_ENV=dev ([#749](https://github.com/expert-lsp/expert/issues/749)) ([aefdcaa](https://github.com/expert-lsp/expert/commit/aefdcaaca6cae1d5cee98b83254acfdf4d7b5726))
* correctly pass Elixir source path config ([#760](https://github.com/expert-lsp/expert/issues/760)) ([762d145](https://github.com/expert-lsp/expert/commit/762d145c9cc3a9ddfc1dfdbbbfb9c33f71865426))
* diagnostics take a long time to update ([#871](https://github.com/expert-lsp/expert/issues/871)) ([f9c8099](https://github.com/expert-lsp/expert/commit/f9c809945d21f3e543d96bee5e37104216fffb75))
* don't connect to the epmd daemon ([#553](https://github.com/expert-lsp/expert/issues/553)) ([292ed7a](https://github.com/expert-lsp/expert/commit/292ed7a40ec8d2d9de035c2b516b613003223224))
* don't discard multiple diagnostics from file and project compilation ([#841](https://github.com/expert-lsp/expert/issues/841)) ([91b1f74](https://github.com/expert-lsp/expert/commit/91b1f74c4102ebe76f61b30645d7063dc5033203))
* don't index build paths ([#652](https://github.com/expert-lsp/expert/issues/652)) ([e19117d](https://github.com/expert-lsp/expert/commit/e19117d5165d1e480675a9809698e2661a8332f0))
* don't infinitely loop prompting to fetch dependencies if it fails ([#548](https://github.com/expert-lsp/expert/issues/548)) ([335c68b](https://github.com/expert-lsp/expert/commit/335c68b4c87072836350d6ee11cdb10840264855))
* don't load deps before the project is compiled ([#839](https://github.com/expert-lsp/expert/issues/839)) ([861c700](https://github.com/expert-lsp/expert/commit/861c7000dcace9aa83f0a65694433cab3a0bd473))
* don't reverse text document params ([#884](https://github.com/expert-lsp/expert/issues/884)) ([01b9f4a](https://github.com/expert-lsp/expert/commit/01b9f4a323d05eb76f33e00f7771bd82dbe75695))
* don't use token_metadata option when compiling ([#845](https://github.com/expert-lsp/expert/issues/845)) ([0f766d0](https://github.com/expert-lsp/expert/commit/0f766d007555c0470f8a9393926b72e2dcbeb755))
* eager loading for large projects ([#610](https://github.com/expert-lsp/expert/issues/610)) ([81f324f](https://github.com/expert-lsp/expert/commit/81f324f153d89a15573b437b49e1d97cda772004))
* engine build crashes when changing tooling versions ([#710](https://github.com/expert-lsp/expert/issues/710)) ([2b307c9](https://github.com/expert-lsp/expert/commit/2b307c9e4074f285b2d6718454a1eb5ee15a48f3))
* **engine:** add project stack lock ([#654](https://github.com/expert-lsp/expert/issues/654)) ([d1cac1d](https://github.com/expert-lsp/expert/commit/d1cac1d9af33acacc0c41f87701e244a995465d2))
* **engine:** analyzer gets confused with overlapping aliases ([#816](https://github.com/expert-lsp/expert/issues/816)) ([ff8e68f](https://github.com/expert-lsp/expert/commit/ff8e68fb4ac6f79ffa5b58570416fd5bcb7e1cb4))
* **engine:** correct project path checks on Windows ([#757](https://github.com/expert-lsp/expert/issues/757)) ([03ff52c](https://github.com/expert-lsp/expert/commit/03ff52c27c925d9563e6941c716bc47d0395c5db))
* **engine:** don't crash in EEx on hover ([#666](https://github.com/expert-lsp/expert/issues/666)) ([822e35e](https://github.com/expert-lsp/expert/commit/822e35eb272c59319e1fb1dfd2a612c0d2e4d151))
* **engine:** drop edit window to 100ms ([#872](https://github.com/expert-lsp/expert/issues/872)) ([05594aa](https://github.com/expert-lsp/expert/commit/05594aa89bde8b091dd530183d380ae14bfa77f8))
* **engine:** fix interpreting words inside strings as identifiers ([#579](https://github.com/expert-lsp/expert/issues/579)) ([8926a03](https://github.com/expert-lsp/expert/commit/8926a036e1b60174d1d66daf8fdd1fcbbc100783))
* **engine:** improve compatibility check messaging ([#716](https://github.com/expert-lsp/expert/issues/716)) ([fc0b737](https://github.com/expert-lsp/expert/commit/fc0b7373b60a5c0cde41f543a6cdb16d9c80b968))
* **engine:** improve progress notifications ([#803](https://github.com/expert-lsp/expert/issues/803)) ([ecbaa7d](https://github.com/expert-lsp/expert/commit/ecbaa7d0a23fe7b3a77f4ad23c99f267038f9ac7))
* **engine:** increase build timeout duration, add batch uri reindex with debounce ([#698](https://github.com/expert-lsp/expert/issues/698)) ([ba07dcd](https://github.com/expert-lsp/expert/commit/ba07dcd442fc18a6e60d3ba6e45ceed55b3611e5))
* **engine:** preload deps and don't prune code paths ([#768](https://github.com/expert-lsp/expert/issues/768)) ([ccce6af](https://github.com/expert-lsp/expert/commit/ccce6af6ea91b295b9a483381c99af9edbe11c5a))
* **engine:** resolve entity with correct arity in (h)eex ([#663](https://github.com/expert-lsp/expert/issues/663)) ([1fefc5c](https://github.com/expert-lsp/expert/commit/1fefc5c8aad43b992834dccef156c61640fbd9da))
* **engine:** resolve formatter against project mix config ([#834](https://github.com/expert-lsp/expert/issues/834)) ([cbddc62](https://github.com/expert-lsp/expert/commit/cbddc6238561951f4f5b995b328a56be1c9c902f))
* **engine:** respect formatter line length in Refactorex actions ([#571](https://github.com/expert-lsp/expert/issues/571)) ([f12c48a](https://github.com/expert-lsp/expert/commit/f12c48a436ad69f25619be76ace803408d3e0eea))
* **engine:** run formatter in Mix project context ([#711](https://github.com/expert-lsp/expert/issues/711)) ([99f2719](https://github.com/expert-lsp/expert/commit/99f27194a523d6ac3c343da88fbdb4e715c50784))
* **engine:** set target when evaluating config diagnostics ([#731](https://github.com/expert-lsp/expert/issues/731)) ([ea7158c](https://github.com/expert-lsp/expert/commit/ea7158c5d9c8f0a9f146691b4fcf1cdeb4431960))
* **engine:** stop double applying alias suffix when prefix is aliased ([#545](https://github.com/expert-lsp/expert/issues/545)) ([9de53c2](https://github.com/expert-lsp/expert/commit/9de53c22d2a829549356090451a122fa2d0cfd51))
* **engine:** unify import lookup to correctly resolve local calls ([#547](https://github.com/expert-lsp/expert/issues/547)) ([728b76e](https://github.com/expert-lsp/expert/commit/728b76eaeb7495e5df7eefeac32221a533c993f5))
* exclude debug applications with MIX_ENV=prod ([#794](https://github.com/expert-lsp/expert/issues/794)) ([21a488b](https://github.com/expert-lsp/expert/commit/21a488b762ee8e2888e382c638173be23c2ff21c)), closes [#786](https://github.com/expert-lsp/expert/issues/786)
* **expert_credo:** prevent infinite hang in with_stdin/2 ([#372](https://github.com/expert-lsp/expert/issues/372)) ([811578b](https://github.com/expert-lsp/expert/commit/811578b946e774c11776670c94fd3eac13382ed3))
* **expert:** add no-op handler for $/setTrace ([#564](https://github.com/expert-lsp/expert/issues/564)) ([4f425a2](https://github.com/expert-lsp/expert/commit/4f425a25439fa507ccfe475c0840cbeb866454c3))
* **expert:** always scrub env vars ([#703](https://github.com/expert-lsp/expert/issues/703)) ([b501d67](https://github.com/expert-lsp/expert/commit/b501d67afd3b139de61adb6f54d762ffc6683dfa))
* **expert:** correct use translation ([#767](https://github.com/expert-lsp/expert/issues/767)) ([1519e99](https://github.com/expert-lsp/expert/commit/1519e99082385f2874978cb7c7a9352c465c2d50))
* **expert:** extend list of editors having VSCode completion bug ([#736](https://github.com/expert-lsp/expert/issues/736)) ([c0494e9](https://github.com/expert-lsp/expert/commit/c0494e9f338233d1c3909224c0b57d862eb46aeb))
* **expert:** fix Node.start for Elixir pre-1.19 ([#720](https://github.com/expert-lsp/expert/issues/720)) ([bbb466c](https://github.com/expert-lsp/expert/commit/bbb466ca61a7de3dadc396b09acf7710197caf72))
* **expert:** force unicode encoding on IO ([#852](https://github.com/expert-lsp/expert/issues/852)) ([ee84f46](https://github.com/expert-lsp/expert/commit/ee84f4638a7a358c0395726f1c330d52174417cf))
* **expert:** log correct path when looking up executables ([#675](https://github.com/expert-lsp/expert/issues/675)) ([4dff00f](https://github.com/expert-lsp/expert/commit/4dff00f67c2560d27e7bc975dd60a956534cbee1))
* **expert:** remote shell command on Windows ([#657](https://github.com/expert-lsp/expert/issues/657)) ([ee2ab46](https://github.com/expert-lsp/expert/commit/ee2ab46a931a7368757228835454184b1a669001))
* **expert:** remove release root entries from subprocess PATH ([#699](https://github.com/expert-lsp/expert/issues/699)) ([a101caa](https://github.com/expert-lsp/expert/commit/a101caa6b19abd5c3faffc167adb50a5d1cab6d8))
* **expert:** use document from request as fallback when document is not in the store ([#693](https://github.com/expert-lsp/expert/issues/693)) ([5daee68](https://github.com/expert-lsp/expert/commit/5daee6889d95c04a3b21fd3db8f6395e31c63e0c))
* **forge:** handle bitstrings in interpolation ([#865](https://github.com/expert-lsp/expert/issues/865)) ([b979b9b](https://github.com/expert-lsp/expert/commit/b979b9b628eee9fac66fbe52fe3b7ba80d005317)), closes [#256](https://github.com/expert-lsp/expert/issues/256)
* **forge:** monitor beam rewriting worker process ([#370](https://github.com/expert-lsp/expert/issues/370)) ([c8be4e9](https://github.com/expert-lsp/expert/commit/c8be4e9690da8c4439ed1f5f6a24e8820dc2a4c4))
* **forge:** normalize Erlang release candidate versions ([#639](https://github.com/expert-lsp/expert/issues/639)) ([babcd42](https://github.com/expert-lsp/expert/commit/babcd4229eed4a5c6c9a4baa5eb1c3566115643b)), closes [#640](https://github.com/expert-lsp/expert/issues/640)
* **forge:** reset ASCII assumption on a new line ([#687](https://github.com/expert-lsp/expert/issues/687)) ([b59dd76](https://github.com/expert-lsp/expert/commit/b59dd76507f94580855612c86aafbbf4c22f9765)), closes [#623](https://github.com/expert-lsp/expert/issues/623)
* **forge:** use `project.root_uri` for cache key in `Forge.Project.config` ([#575](https://github.com/expert-lsp/expert/issues/575)) ([deb019b](https://github.com/expert-lsp/expert/commit/deb019b867dfaabd641b0063a2dba59fe91b5b46))
* handle LSP supported invalid configuration values ([#551](https://github.com/expert-lsp/expert/issues/551)) ([e973cfc](https://github.com/expert-lsp/expert/commit/e973cfcc85e9e19153e8d78202870fc3acf3b9b5))
* hang at startup if .bashrc contains exec call ([#527](https://github.com/expert-lsp/expert/issues/527)) ([73b8d28](https://github.com/expert-lsp/expert/commit/73b8d288d92f319ee8920f0dde1e0206b13e4c0f))
* improve performance of formatting ([#804](https://github.com/expert-lsp/expert/issues/804)) ([63ae6eb](https://github.com/expert-lsp/expert/commit/63ae6eb96821b8e8eef07573241ea2fee4ce9dc1))
* improve release overlays ([#578](https://github.com/expert-lsp/expert/issues/578)) ([3ee0a1b](https://github.com/expert-lsp/expert/commit/3ee0a1b8c947d0dee5d4f11a5c44990450baef39))
* improve startup time and module introspection ([#604](https://github.com/expert-lsp/expert/issues/604)) ([f0a788a](https://github.com/expert-lsp/expert/commit/f0a788a39141d2fbc1718ac21a6a65c49b54684d))
* improve struct reference completion handling errors in struct completions ([#774](https://github.com/expert-lsp/expert/issues/774)) ([c5674bc](https://github.com/expert-lsp/expert/commit/c5674bcc83933355eeb0ad779fed0119ec631739))
* incorrect undefined protocol function diagnostic ([#820](https://github.com/expert-lsp/expert/issues/820)) ([77a6e74](https://github.com/expert-lsp/expert/commit/77a6e7401b83ab39f0542605e098d96451e9c63f))
* index macro-generated definitions from compiler traces ([#856](https://github.com/expert-lsp/expert/issues/856)) ([d564f25](https://github.com/expert-lsp/expert/commit/d564f25af59e21266500c4adba6fa8814d4f0c4b))
* index project sources even when compile reports error ([#809](https://github.com/expert-lsp/expert/issues/809)) ([5039c10](https://github.com/expert-lsp/expert/commit/5039c10d49ff8a4ec6344ef87b01262781f65ff5))
* make sure to return only Diagnostic.Result struct as diagnostics ([#782](https://github.com/expert-lsp/expert/issues/782)) ([c763351](https://github.com/expert-lsp/expert/commit/c7633513898c3696f33514fc5780631c7adb8bd3))
* only index sibling beams when origin source file changes ([#707](https://github.com/expert-lsp/expert/issues/707)) ([03a56b5](https://github.com/expert-lsp/expert/commit/03a56b541a10dd3985921cdf14e86280e82254cb))
* port Refactorex into Forge ([#747](https://github.com/expert-lsp/expert/issues/747)) ([c27bf61](https://github.com/expert-lsp/expert/commit/c27bf61a837fd64e47a80c09b1ff1b9420a98eae))
* prevent formatter cache from forgetting the formatter for a path ([#831](https://github.com/expert-lsp/expert/issues/831)) ([8bc8afc](https://github.com/expert-lsp/expert/commit/8bc8afca704e78d6f7c38ae42d9a95915281f0f5))
* properly calculate callback completion line range ([#846](https://github.com/expert-lsp/expert/issues/846)) ([627309d](https://github.com/expert-lsp/expert/commit/627309dffbe5ebc9fdf8eed29bfc596d6f04e24e)), closes [#785](https://github.com/expert-lsp/expert/issues/785)
* properly handle typespec errors; prevent diagnostics crash ([#879](https://github.com/expert-lsp/expert/issues/879)) ([eb0a7e4](https://github.com/expert-lsp/expert/commit/eb0a7e41df46896fbfcd2cb903fa33f6d3399ff1))
* record module binary if module metata read fails ([#874](https://github.com/expert-lsp/expert/issues/874)) ([cf76479](https://github.com/expert-lsp/expert/commit/cf764796c8baf54148e4afb6082cdcf7ed53394e))
* **refactorex:** use field-level comparison for cursor detection ([#642](https://github.com/expert-lsp/expert/issues/642)) ([14e59a4](https://github.com/expert-lsp/expert/commit/14e59a46f628930528352a64055e146330ce5d78))
* relax Hex connectivity timeout ([#858](https://github.com/expert-lsp/expert/issues/858)) ([423be25](https://github.com/expert-lsp/expert/commit/423be2589179d7c1a4b6d333a1c2676e285bfae7)), closes [#538](https://github.com/expert-lsp/expert/issues/538)
* **release:** ensure start_expert works if symlinked ([#572](https://github.com/expert-lsp/expert/issues/572)) ([c11f489](https://github.com/expert-lsp/expert/commit/c11f489a2ce845240d2834b2da8d7f84e91e1eec))
* rework workspace folders and project discovery ([#566](https://github.com/expert-lsp/expert/issues/566)) ([345aa34](https://github.com/expert-lsp/expert/commit/345aa3452540034d4b531b9cd25c1a8a387dc940))
* schedule compiles for ready engines only ([#762](https://github.com/expert-lsp/expert/issues/762)) ([7dd317b](https://github.com/expert-lsp/expert/commit/7dd317bf908df4c7491be60969fde4a7fa6a7b72))
* skip regular files on engine clean ([#613](https://github.com/expert-lsp/expert/issues/613)) ([ce93691](https://github.com/expert-lsp/expert/commit/ce93691f9983310a79cc13122e3a65749273a73b))
* stop calls to `IO` and other writes to stdout from crashing Expert. ([#824](https://github.com/expert-lsp/expert/issues/824)) ([f76b96a](https://github.com/expert-lsp/expert/commit/f76b96a45d3dd43a7f49a029ff436429075f479c))


### Performance Improvements

* avoid forced warm-start compiles ([#866](https://github.com/expert-lsp/expert/issues/866)) ([81f13e6](https://github.com/expert-lsp/expert/commit/81f13e6239125ac0e33d7e0968b49c3bdc75d393)), closes [#863](https://github.com/expert-lsp/expert/issues/863)
* **indexer:** cache application and available modules ([#634](https://github.com/expert-lsp/expert/issues/634)) ([9bc521d](https://github.com/expert-lsp/expert/commit/9bc521d694db52feb85c5830e93a4c15cdc271a4))
* **indexer:** only use relevant extractors when indexing deps ([#641](https://github.com/expert-lsp/expert/issues/641)) ([161f040](https://github.com/expert-lsp/expert/commit/161f040d55956037f78e3ec04832596dad92188f))
* use beam metadata for dependencies ([#670](https://github.com/expert-lsp/expert/issues/670)) ([710c736](https://github.com/expert-lsp/expert/commit/710c7368ddb8a1f64434796e3db3e92c4f6c2e4d))


### Reverts

* downgrade burrito to 1.5 and zig to 0.15.0 ([#844](https://github.com/expert-lsp/expert/issues/844)) ([0215beb](https://github.com/expert-lsp/expert/commit/0215beb2fc100332d9dd6d1daed336e1edcf2fbc))
* feat: use compiler tracers for project indexing ([#705](https://github.com/expert-lsp/expert/issues/705)) ([#763](https://github.com/expert-lsp/expert/issues/763)) ([d79e0b7](https://github.com/expert-lsp/expert/commit/d79e0b727e9624f39a4cee23ed89c5567dccfac0))

## [0.1.0](https://github.com/expert-lsp/expert/compare/v0.1.0-rc.6...v0.1.0) (2026-03-27)


### Bug Fixes

* **engine:** only start one engine for umbrella apps ([#462](https://github.com/expert-lsp/expert/issues/462)) ([f674d3d](https://github.com/expert-lsp/expert/commit/f674d3da196344c96d14e1bfbc90eca8eab0b3cb)), closes [#460](https://github.com/expert-lsp/expert/issues/460)
* extractor not working with ExUnit.CaseTemplate ([#529](https://github.com/expert-lsp/expert/issues/529)) ([11fb790](https://github.com/expert-lsp/expert/commit/11fb79058fe35966d58e1fc436f768690a671e2a))
* **forge:** id generator must not create duplicate IDs ([#499](https://github.com/expert-lsp/expert/issues/499)) ([7a4e333](https://github.com/expert-lsp/expert/commit/7a4e33347e0005d4ec10c9f5ef94148983bb9f96))
* issues with creating `.expert` directory too eagerly ([#520](https://github.com/expert-lsp/expert/issues/520)) ([1c51871](https://github.com/expert-lsp/expert/commit/1c51871bbb68bbbdb4031fe425b2c3540c2cc619))
* prevent recursive alias generation for nested modules ([#505](https://github.com/expert-lsp/expert/issues/505)) ([7596f9c](https://github.com/expert-lsp/expert/commit/7596f9c2f84a29f968ef330917d3355d876eab04))
* startup and tests on Windows ([#518](https://github.com/expert-lsp/expert/issues/518)) ([a2a2947](https://github.com/expert-lsp/expert/commit/a2a29470fb5e39c9942c9fd8cdbafe9da95d95c8)), closes [#515](https://github.com/expert-lsp/expert/issues/515)


### Performance Improvements

* **engine:** load module store after build ([#519](https://github.com/expert-lsp/expert/issues/519)) ([e73266d](https://github.com/expert-lsp/expert/commit/e73266d29f20dc4d9456583204f849033f297cfc))


### Miscellaneous Chores

* release as 0.1.0 ([1bbd0df](https://github.com/expert-lsp/expert/commit/1bbd0df1ebc79621919096ae4c6f911bf5d91336))

## [0.1.0-rc.6](https://github.com/expert-lsp/expert/compare/v0.1.0-rc.5...v0.1.0-rc.6) (2026-03-10)


### Features

* configure lsp log level ([#488](https://github.com/expert-lsp/expert/issues/488)) ([f536fc6](https://github.com/expert-lsp/expert/commit/f536fc6ed7e2714c5526e36cb366503a164126a4))


### Bug Fixes

* add Project.unique_name to allow multiple project with same root folder name ([#458](https://github.com/expert-lsp/expert/issues/458)) ([d1b4889](https://github.com/expert-lsp/expert/commit/d1b4889c6c9f22a27eab50cbe20fe0e1046906d5))
* bump Spitfire to v0.3.10 ([#491](https://github.com/expert-lsp/expert/issues/491)) ([335f022](https://github.com/expert-lsp/expert/commit/335f0224f23a9da52e1555319e570c964d1b842a))
* **engine:** add missing rescue for `:ets.lookup_element` ([#494](https://github.com/expert-lsp/expert/issues/494)) ([f4884f4](https://github.com/expert-lsp/expert/commit/f4884f43dbcd5991a46e9a4af299217f22c54f9a))
* **expert:** display user-friendly message on filesystem error ([#495](https://github.com/expert-lsp/expert/issues/495)) ([021da96](https://github.com/expert-lsp/expert/commit/021da96be08bb15220d12317a00430c0ab743b53))
* fetch `hex` and `rebar` in all places ([#490](https://github.com/expert-lsp/expert/issues/490)) ([48b5ad0](https://github.com/expert-lsp/expert/commit/48b5ad0b1d65b35c4b59f718c9a14ef4f072511c))
* **forge:** fix parent check to not give false positive on some siblings ([#472](https://github.com/expert-lsp/expert/issues/472)) ([44a43e2](https://github.com/expert-lsp/expert/commit/44a43e2d146ddb1a5cd9cce35b5cd7cd8947a94f))
* only index tests if ExUnit.Case is in scope ([#480](https://github.com/expert-lsp/expert/issues/480)) ([a7b685d](https://github.com/expert-lsp/expert/commit/a7b685dfc0d4ab3f813a0d2389179ea681c2534f))
* rotate expert.log files ([#489](https://github.com/expert-lsp/expert/issues/489)) ([90d7d81](https://github.com/expert-lsp/expert/commit/90d7d81fe537c486547b99fa4cfb3d4e52a7f19c))


### Performance Improvements

* use "Expert ID" instead of Snowflake ([#479](https://github.com/expert-lsp/expert/issues/479)) ([1743567](https://github.com/expert-lsp/expert/commit/174356760339056679d32561eb9f5d7132d63509)), closes [#471](https://github.com/expert-lsp/expert/issues/471)

## [0.1.0-rc.5](https://github.com/expert-lsp/expert/compare/v0.1.0-rc.4...v0.1.0-rc.5) (2026-02-26)


### Bug Fixes

* build engines to `:user_cache` instead of `:user_data` ([#467](https://github.com/expert-lsp/expert/issues/467)) ([5c65a97](https://github.com/expert-lsp/expert/commit/5c65a97bf2695d9ed367248ac53750e8b4930dfb))

## [0.1.0-rc.4](https://github.com/expert-lsp/expert/compare/v0.1.0-rc.3...v0.1.0-rc.4) (2026-02-26)


### Bug Fixes

* correctly handle port lines when building the engine ([#463](https://github.com/expert-lsp/expert/issues/463)) ([d795c70](https://github.com/expert-lsp/expert/commit/d795c70982a8ab39a06b91c72942ea7988c03657))

## [0.1.0-rc.3](https://github.com/expert-lsp/expert/compare/v0.1.0-rc.2...v0.1.0-rc.3) (2026-02-26)


### Bug Fixes

* **engine:** skip unquoted aliases ([#452](https://github.com/expert-lsp/expert/issues/452)) ([9c5c89a](https://github.com/expert-lsp/expert/commit/9c5c89a1e4ebbd457e4a5d5b59eebf8d827508a4))
* **expert:** always use MIX_ENV=dev when building engine ([#442](https://github.com/expert-lsp/expert/issues/442)) ([60cc5b7](https://github.com/expert-lsp/expert/commit/60cc5b720cfd1860fe66d54a7ee23257b87acae4)), closes [#431](https://github.com/expert-lsp/expert/issues/431)
* **expert:** honor users PATH ([#456](https://github.com/expert-lsp/expert/issues/456)) ([c003eba](https://github.com/expert-lsp/expert/commit/c003eba58d2ef60121b29c8d05071156f520ec7d))
* **expert:** send correct version in server_info ([#457](https://github.com/expert-lsp/expert/issues/457)) ([31a4226](https://github.com/expert-lsp/expert/commit/31a4226d48c2e21514115decd7120d8174201b5c))
* isolate engine builds and retry them on dependency errors ([#454](https://github.com/expert-lsp/expert/issues/454)) ([3205d56](https://github.com/expert-lsp/expert/commit/3205d5649b94c88db138175a3e6a79fd47d174cb))
* make Refactorex available on all trigger kinds ([#445](https://github.com/expert-lsp/expert/issues/445)) ([97c810b](https://github.com/expert-lsp/expert/commit/97c810bf8a7d4522a75e13bd1cdcee7adf07d8bd))
* properly setup logger ([#455](https://github.com/expert-lsp/expert/issues/455)) ([ba10ae8](https://github.com/expert-lsp/expert/commit/ba10ae87cae1247a47ae26106161c599fefae1f4))

## [0.1.0-rc.2](https://github.com/expert-lsp/expert/compare/v0.1.0-rc.1...v0.1.0-rc.2) (2026-02-24)


### Features

* add `instance_id` metadata to logs ([#380](https://github.com/expert-lsp/expert/issues/380)) ([5c209be](https://github.com/expert-lsp/expert/commit/5c209be7490c44be6c3c12ca13058ddc16b91912))


### Bug Fixes

* ensure `MIX_BUILD_PATH` is set for child processes ([#436](https://github.com/expert-lsp/expert/issues/436)) ([3178302](https://github.com/expert-lsp/expert/commit/31783023c9ba4b0152a76aa255572867cca1abe7))
* **expert:** check start_child return in initialized handler ([#371](https://github.com/expert-lsp/expert/issues/371)) ([de979ce](https://github.com/expert-lsp/expert/commit/de979ceabaa108a3e5eb43a7675f13ac913ac76b))
* forward logs through window log handler ([#418](https://github.com/expert-lsp/expert/issues/418)) ([c608dc8](https://github.com/expert-lsp/expert/commit/c608dc84597193a2875714636ad2eebf40820ad5)), closes [#382](https://github.com/expert-lsp/expert/issues/382)
* support multiple elixir versions on multiroot projects ([#413](https://github.com/expert-lsp/expert/issues/413)) ([dee595d](https://github.com/expert-lsp/expert/commit/dee595d9040416f9036eaa355ac645a8f35da202))

## [0.1.0-rc.1](https://github.com/expert-lsp/expert/compare/v0.1.0-rc.0...v0.1.0-rc.1) (2026-02-22)


### Features

* prompt user to fetch deps when they get out of sync ([#405](https://github.com/expert-lsp/expert/issues/405)) ([fc16ddc](https://github.com/expert-lsp/expert/commit/fc16ddc14395817766f9ac9c902dde08d6e63f7d))


### Bug Fixes

* build expert on latest nixpkgs ([#422](https://github.com/expert-lsp/expert/issues/422)) ([d3eb92c](https://github.com/expert-lsp/expert/commit/d3eb92cf16ef154ddd7cd08d1135fd9d44c8bff0))
* bump spitfire v0.3.7 ([#425](https://github.com/expert-lsp/expert/issues/425)) ([ce508c8](https://github.com/expert-lsp/expert/commit/ce508c868efe8cc1ca07299f9dda249be7df3525))
* **engine:** don't collect sibling scopes in Phoenix router ([#420](https://github.com/expert-lsp/expert/issues/420)) ([b72bfc8](https://github.com/expert-lsp/expert/commit/b72bfc839a372138abbc30ac9cef3c1f6625ff81))
* **expert:** don't crash on missing root_uri ([#412](https://github.com/expert-lsp/expert/issues/412)) ([11ed716](https://github.com/expert-lsp/expert/commit/11ed7167a5007075c254b38fbe72586afbfe6b65))
* **forge:** progress message ordering ([#427](https://github.com/expert-lsp/expert/issues/427)) ([f3b9187](https://github.com/expert-lsp/expert/commit/f3b9187911da7906131b2f96406c3a1f7e95bd74))
* migrate expert runtime logging to OTP handlers ([#419](https://github.com/expert-lsp/expert/issues/419)) ([8f2dda5](https://github.com/expert-lsp/expert/commit/8f2dda5f03de40419d10bd88b3072176c868f7c3))
* provide typespec docs on hover for private functions ([#407](https://github.com/expert-lsp/expert/issues/407)) ([79c5451](https://github.com/expert-lsp/expert/commit/79c54513b8bb1a9e1eff2f7c32d4ff8354c8d0fa))


### Miscellaneous Chores

* release as 0.1.0-rc.1 ([6f5986e](https://github.com/expert-lsp/expert/commit/6f5986eced5090b2df17b0c0cb659180eafd047a))

## [0.1.0-rc.0](https://github.com/expert-lsp/expert/compare/v0.1.0...v0.1.0-rc.0) (2026-02-19)


### ⚠ BREAKING CHANGES

* add CLI flag handling ([#185](https://github.com/expert-lsp/expert/issues/185))

### Features

* add CLI flag handling ([#185](https://github.com/expert-lsp/expert/issues/185)) ([46713a1](https://github.com/expert-lsp/expert/commit/46713a173b595f1bc2d1ce6e6f747a135291a392))
* add engine subcommands to expert ([#254](https://github.com/expert-lsp/expert/issues/254)) ([d7c348c](https://github.com/expert-lsp/expert/commit/d7c348cd5682dd0fd5fef04b56e8d9058b76ced6))
* add missing require code action ([#283](https://github.com/expert-lsp/expert/issues/283)) ([a9ee0ec](https://github.com/expert-lsp/expert/commit/a9ee0ec8617f8bee70aa9d1431ff4d4930a8fb29))
* configure Workspace Symbols to return all symbols on empty query ([#293](https://github.com/expert-lsp/expert/issues/293)) ([03ec5c6](https://github.com/expert-lsp/expert/commit/03ec5c6cd614bc17c7ec3d68d1cf5f7c2ed185bb))
* create undefined function code action ([#287](https://github.com/expert-lsp/expert/issues/287)) ([9624b3a](https://github.com/expert-lsp/expert/commit/9624b3ab1010b15d6cbb5d238d26a1a922936fbb))
* **engine:** hover for module attributes ([#329](https://github.com/expert-lsp/expert/issues/329)) ([1330370](https://github.com/expert-lsp/expert/commit/1330370cfa5693e246cba4a381e1948e6a090ff0))
* **engine:** indicate progress when loading checkpoint ([#313](https://github.com/expert-lsp/expert/issues/313)) ([fad5a0b](https://github.com/expert-lsp/expert/commit/fad5a0b24eefaaf14ddc73b52ea2f66711083492))
* **engine:** support shorthand notation inside ~H sigil ([#278](https://github.com/expert-lsp/expert/issues/278)) ([e1e5666](https://github.com/expert-lsp/expert/commit/e1e5666dafccc24b1116eed8ad20a34cf667e9b8))
* **engine:** use ElixirSense for hover resolution ([#351](https://github.com/expert-lsp/expert/issues/351)) ([0e7896b](https://github.com/expert-lsp/expert/commit/0e7896bdc48d07d46eb6e2e8e842cefe6c019cba))
* epmdless clustering ([#205](https://github.com/expert-lsp/expert/issues/205)) ([488d3a9](https://github.com/expert-lsp/expert/commit/488d3a95e2c6eb2deb600ebf6cd5525232997b9b))
* epmdless deployments ([#167](https://github.com/expert-lsp/expert/issues/167)) ([9cfb5cc](https://github.com/expert-lsp/expert/commit/9cfb5cc57ea7458a7e67559e91332dd549b638fc))
* on the fly engine builds ([#24](https://github.com/expert-lsp/expert/issues/24)) ([51eb6f1](https://github.com/expert-lsp/expert/commit/51eb6f1523f7580e060fdc1d494872fb4909a0ee))
* use Spitfire to provide document symbols on documents with syntax errors ([#288](https://github.com/expert-lsp/expert/issues/288)) ([2ed7a81](https://github.com/expert-lsp/expert/commit/2ed7a81e2361ac56933dff8be494675313972cb6))
* windows support ([#219](https://github.com/expert-lsp/expert/issues/219)) ([d0927ce](https://github.com/expert-lsp/expert/commit/d0927ceea79989c6d9a7508ac18e75f42939627f))
* workspace folders ([#18](https://github.com/expert-lsp/expert/issues/18)) ([1204313](https://github.com/expert-lsp/expert/commit/1204313371da69029eb275235254f4d67905fa47)), closes [#136](https://github.com/expert-lsp/expert/issues/136)


### Bug Fixes

* add lsp logging when failing to find an elixir executable ([#169](https://github.com/expert-lsp/expert/issues/169)) ([4dfba22](https://github.com/expert-lsp/expert/commit/4dfba220c97651c0f2c9eaf4b1c12d22c2055f37))
* avoid crashing when calling `ActiveProjects.active?/1` ([#297](https://github.com/expert-lsp/expert/issues/297)) ([ae352b9](https://github.com/expert-lsp/expert/commit/ae352b98d739b37c6c9d5d63ad29c069425794ef))
* better handling of native&lt;-&gt;lsp conversions ([#34](https://github.com/expert-lsp/expert/issues/34)) ([88dc456](https://github.com/expert-lsp/expert/commit/88dc4565c4069923ff958c6b7a6e541d45202806))
* bring back completions for things defined in test files ([#32](https://github.com/expert-lsp/expert/issues/32)) ([8d7a47a](https://github.com/expert-lsp/expert/commit/8d7a47af188d6e54213f704d977e25eff1150b5a))
* clamp start_char for comletion prefix ([#239](https://github.com/expert-lsp/expert/issues/239)) ([46d3446](https://github.com/expert-lsp/expert/commit/46d34461a731d0ef55f0c57980e9b67b1a0716cb))
* **cli:** don't crash when there is no CLI arg provided ([#348](https://github.com/expert-lsp/expert/issues/348)) ([9a9140e](https://github.com/expert-lsp/expert/commit/9a9140ed921c28a14663923be7a2331e00764f71))
* **cli:** show per tool version engine builds ([#301](https://github.com/expert-lsp/expert/issues/301)) ([399b2a0](https://github.com/expert-lsp/expert/commit/399b2a093e464446b14facccc16f2a073265d499))
* correctly order aliases ([#322](https://github.com/expert-lsp/expert/issues/322)) ([fb269fa](https://github.com/expert-lsp/expert/commit/fb269fac05de62fff21cd05f0dc1917729953753))
* Crash when typing english ([#742](https://github.com/expert-lsp/expert/issues/742)) ([697eac9](https://github.com/expert-lsp/expert/commit/697eac93a6cc9e8e0cd3835504c72fcdf6208d0a)), closes [#741](https://github.com/expert-lsp/expert/issues/741)
* Current module not identified in defimpl ([#665](https://github.com/expert-lsp/expert/issues/665)) ([29f1055](https://github.com/expert-lsp/expert/commit/29f10553be303ad16918a14a4fcf96accd99e1e7))
* **deps:** update sourceror to 1.10.1 to fix range calculations ([#362](https://github.com/expert-lsp/expert/issues/362)) ([59489c7](https://github.com/expert-lsp/expert/commit/59489c75437307c61f544f2dfae2201e03b00f70))
* disable shell sessions when fetching the PATH ([#177](https://github.com/expert-lsp/expert/issues/177)) ([78236ef](https://github.com/expert-lsp/expert/commit/78236ef073c45222720c8e950e618a4289e81650))
* do not clamp character recvd from client ([#123](https://github.com/expert-lsp/expert/issues/123)) ([1a3b843](https://github.com/expert-lsp/expert/commit/1a3b843adb441da80e330d04702e3eda4d9d79ba))
* don't convert to_lsp twice in server specific messages ([#190](https://github.com/expert-lsp/expert/issues/190)) ([33bb850](https://github.com/expert-lsp/expert/commit/33bb85032e53f1adc70c67a7b518047d4f0d352e))
* don't sometimes hang ([5d6bcde](https://github.com/expert-lsp/expert/commit/5d6bcde857a2b318cf19168c7c4b6c8a4dddc63a))
* Edge case for module loading ([#738](https://github.com/expert-lsp/expert/issues/738)) ([dbbef2c](https://github.com/expert-lsp/expert/commit/dbbef2c48f655ecdfe116f157c2ffeb261083757))
* elixir path discovery ([#248](https://github.com/expert-lsp/expert/issues/248)) ([f9b119c](https://github.com/expert-lsp/expert/commit/f9b119c945f4aa3f3be7876ad7931fc52d8bf4c6))
* **engine_node:** error reason not being shown ([#277](https://github.com/expert-lsp/expert/issues/277)) ([c7b7fa8](https://github.com/expert-lsp/expert/commit/c7b7fa849ca1786f62ba2d5bdb034526fae796f0))
* **engine:** avoid duplicate spec annotation when falling back to ElixirSense ([#410](https://github.com/expert-lsp/expert/issues/410)) ([5b4faee](https://github.com/expert-lsp/expert/commit/5b4faee7943b36e62890c4ae1143ce46f37db839))
* **engine:** code lens exception when mix.exs not found ([#281](https://github.com/expert-lsp/expert/issues/281)) ([f9c81da](https://github.com/expert-lsp/expert/commit/f9c81da38640240e81aa97d51d1ed8ccaee08696))
* **engine:** correctly match any-struct references ([#347](https://github.com/expert-lsp/expert/issues/347)) ([6a92581](https://github.com/expert-lsp/expert/commit/6a925814d74b1bac39e60f4a1ee6e4689e8a90a1))
* **engine:** don't attempt search when ETS checkpoint is loading ([#308](https://github.com/expert-lsp/expert/issues/308)) ([438c965](https://github.com/expert-lsp/expert/commit/438c965ce6943651688e3349b782d64b2459a6c2))
* **engine:** don't crash on hover for piped expression in curly braces in HEEx ([#350](https://github.com/expert-lsp/expert/issues/350)) ([f0044d6](https://github.com/expert-lsp/expert/commit/f0044d6b6442f4308bb4b3854012f982bfc7077b))
* **engine:** don't crash when calling references on an atom ([#396](https://github.com/expert-lsp/expert/issues/396)) ([a8badfc](https://github.com/expert-lsp/expert/commit/a8badfcf99a83856475a278d9365730a8e1ab842))
* **engine:** don't terminate search store on timeout ([#338](https://github.com/expert-lsp/expert/issues/338)) ([d91f6af](https://github.com/expert-lsp/expert/commit/d91f6af0fb7c78a9da1aa0c83787783dee94507e)), closes [#303](https://github.com/expert-lsp/expert/issues/303)
* **engine:** download Hex and Rebar only if missing ([#337](https://github.com/expert-lsp/expert/issues/337)) ([bc7f57e](https://github.com/expert-lsp/expert/commit/bc7f57e1f5802fc71ce2958529e45eabac005ff9))
* **engine:** handle failing build script ([#188](https://github.com/expert-lsp/expert/issues/188)) ([ce9ac22](https://github.com/expert-lsp/expert/commit/ce9ac22542379c8f8164f98213a3a34aad59544c))
* **engine:** handle matches against any struct ([#343](https://github.com/expert-lsp/expert/issues/343)) ([86fe8ec](https://github.com/expert-lsp/expert/commit/86fe8ec2168c266631e7f3506fcbf0afa6083656))
* **engine:** improve entity resolution for HEEx components with curly braces ([#328](https://github.com/expert-lsp/expert/issues/328)) ([eff68bf](https://github.com/expert-lsp/expert/commit/eff68bf31a8466fb65664f3447c7274166cbf5d5))
* **engine:** index functions with default arguments ([#402](https://github.com/expert-lsp/expert/issues/402)) ([1aea6c7](https://github.com/expert-lsp/expert/commit/1aea6c7c36d7c864f2295c5ab01d10f7315a10bb))
* **engine:** resolve correct arity from inside ~H sigil ([#314](https://github.com/expert-lsp/expert/issues/314)) ([d2eacc0](https://github.com/expert-lsp/expert/commit/d2eacc09737c279a476f0eefbcd2cbc07a6d850b))
* **engine:** stuck on format request ([#378](https://github.com/expert-lsp/expert/issues/378)) ([aa5ba2b](https://github.com/expert-lsp/expert/commit/aa5ba2b92174d75b27dfcb96592b678ad7a62636))
* **engine:** support go to definition when function is called via __MODULE__ ([#261](https://github.com/expert-lsp/expert/issues/261)) ([b1d5e17](https://github.com/expert-lsp/expert/commit/b1d5e179c851e60a0308bfeab7cb2661877161d8))
* Exclude expert dependencies from completions based on project dependencies ([3a47058](https://github.com/expert-lsp/expert/commit/3a47058975610c9a480e05c4a6473966c8ddf2bf))
* **expert:** always log PATH on start ([#387](https://github.com/expert-lsp/expert/issues/387)) ([bfeb8a2](https://github.com/expert-lsp/expert/commit/bfeb8a27f341f6da3caf20d0f8054901080143ef))
* **expert:** build engine for elixir version 1.16.1 and below ([#330](https://github.com/expert-lsp/expert/issues/330)) ([2a2bdd9](https://github.com/expert-lsp/expert/commit/2a2bdd916e76340f8d60939a7b5160ffaf24c4e0))
* **expert:** correctly handle unicode characters sent via port ([#388](https://github.com/expert-lsp/expert/issues/388)) ([4fe530b](https://github.com/expert-lsp/expert/commit/4fe530be71893e30a99ff7eacd48ddb2da44eba3))
* **expert:** print to stderr when no transport argument provided ([#280](https://github.com/expert-lsp/expert/issues/280)) ([fc841e4](https://github.com/expert-lsp/expert/commit/fc841e48be753a5b72e1464c110226dd5f745471))
* **expert:** save new configuration after `workspace/didChangeConfiguration` ([#282](https://github.com/expert-lsp/expert/issues/282)) ([b060d23](https://github.com/expert-lsp/expert/commit/b060d2356f74ad510bb774e4c6be0a5fb5646be3))
* **expert:** spec completions for functions with guards ([#406](https://github.com/expert-lsp/expert/issues/406)) ([d615858](https://github.com/expert-lsp/expert/commit/d615858f8de28a88b53e8786da243fe3feb5e3d5))
* fallback to packaged or system elixir ([#300](https://github.com/expert-lsp/expert/issues/300)) ([10262cf](https://github.com/expert-lsp/expert/commit/10262cf4bf5541e96d1496ba160a7700ab5dc359))
* filter out RELEASE_ROOT from PATH instead of running a login shell ([#344](https://github.com/expert-lsp/expert/issues/344)) ([375391c](https://github.com/expert-lsp/expert/commit/375391c92c8027e06e0c293325384e6c58310a6f))
* fix release-all command ([492022f](https://github.com/expert-lsp/expert/commit/492022fc962feb3f34fbffce173331ead8700894))
* fixup namespacing and packaging ([#29](https://github.com/expert-lsp/expert/issues/29)) ([69ac8fe](https://github.com/expert-lsp/expert/commit/69ac8fe59469b273957746794873371d01c1673f))
* **forge:** don't crash on analysis of code with incorrect aliases ([#408](https://github.com/expert-lsp/expert/issues/408)) ([7c30502](https://github.com/expert-lsp/expert/commit/7c3050216340c55cef92bc86414b791b3889bcfa))
* **forge:** handle interpolation when it starts with a special token ([#342](https://github.com/expert-lsp/expert/issues/342)) ([dd7b027](https://github.com/expert-lsp/expert/commit/dd7b02765635c0cadaa6fe55f86dc5e334e0bada))
* **forge:** improve log when Spitfire crashes ([#352](https://github.com/expert-lsp/expert/issues/352)) ([80900e5](https://github.com/expert-lsp/expert/commit/80900e56c8685ca7b85951b091fa624ea1950ee2))
* formatting format incorrectly when contain special character ([#252](https://github.com/expert-lsp/expert/issues/252)) ([b5b001b](https://github.com/expert-lsp/expert/commit/b5b001b97820694256a2b730f891a4e836437437))
* Function definition extractor chokes on macro functions ([#682](https://github.com/expert-lsp/expert/issues/682)) ([ccf355f](https://github.com/expert-lsp/expert/commit/ccf355f8ca53dab5fe86009d6c2ce687ad399476)), closes [#680](https://github.com/expert-lsp/expert/issues/680)
* give proper argument to `TaskQueue.add/2` in Server.handle_message ([#791](https://github.com/expert-lsp/expert/issues/791)) ([34ee071](https://github.com/expert-lsp/expert/commit/34ee0716681eb346bffba67ce77febc047189b61))
* handle missing metadata in indexer extractors ([#390](https://github.com/expert-lsp/expert/issues/390)) ([71c33f1](https://github.com/expert-lsp/expert/commit/71c33f10ba8ab566a4e12dba024dba3e8c6f7c73))
* handle spitfire crashes ([#319](https://github.com/expert-lsp/expert/issues/319)) ([ffe360c](https://github.com/expert-lsp/expert/commit/ffe360c88e8811e41fbd33d6404acb18f4b7a95e))
* handle string ids in requests ([#120](https://github.com/expert-lsp/expert/issues/120)) ([5d6bcde](https://github.com/expert-lsp/expert/commit/5d6bcde857a2b318cf19168c7c4b6c8a4dddc63a))
* include erlang source files when packaging engine ([580ccc8](https://github.com/expert-lsp/expert/commit/580ccc8c1241e6ae3f8eaf1687ed87d7ab3d1895))
* inherited PATH pollutes project environment ([#298](https://github.com/expert-lsp/expert/issues/298)) ([8e1bb3d](https://github.com/expert-lsp/expert/commit/8e1bb3dc5328ddc6fcab2203767b44a92db0909a))
* interpolation_ranges/1 should work for empty interpolations ([#321](https://github.com/expert-lsp/expert/issues/321)) ([3ec1810](https://github.com/expert-lsp/expert/commit/3ec1810e397bea76d84daa6816a5061d39cc480f))
* Invalid reads for requests that contain multi-byte characters ([#661](https://github.com/expert-lsp/expert/issues/661)) ([f6ca36f](https://github.com/expert-lsp/expert/commit/f6ca36f7b05302e73d76ee2b8b59fa87bfcf6a31))
* let the system figure out the elixir version for the project ([#162](https://github.com/expert-lsp/expert/issues/162)) ([5dacce4](https://github.com/expert-lsp/expert/commit/5dacce456cb111b75c3f1aeeba95b66e1bc07b04))
* log project's erl path ([#367](https://github.com/expert-lsp/expert/issues/367)) ([d8c81cd](https://github.com/expert-lsp/expert/commit/d8c81cd5c686e770d35bcd10ede3980a733e1471))
* make sure asdf shims are in the PATH ([#87](https://github.com/expert-lsp/expert/issues/87)) ([7626f90](https://github.com/expert-lsp/expert/commit/7626f90414c0078eaeda2e03d6aaa05f3383b25e))
* Module suggestion was incorrect for files with multiple periods ([#705](https://github.com/expert-lsp/expert/issues/705)) ([824df66](https://github.com/expert-lsp/expert/commit/824df66203cbd5b4e12846130a4f8dffe0199e3a)), closes [#703](https://github.com/expert-lsp/expert/issues/703)
* nil.__struct__/0 is undefined when receiving shutdown ([#250](https://github.com/expert-lsp/expert/issues/250)) ([849003e](https://github.com/expert-lsp/expert/commit/849003e65cd6bcc5fd91ab5535c854ca4d8412b5))
* **nix:** use eval release command ([#199](https://github.com/expert-lsp/expert/issues/199)) ([25f80c8](https://github.com/expert-lsp/expert/commit/25f80c8e286ac20af5b0a6060795939c4a812859))
* Non-string test names crash exunit indexer ([#676](https://github.com/expert-lsp/expert/issues/676)) ([29373d5](https://github.com/expert-lsp/expert/commit/29373d5816ae161c4cdceb4cce9e8f1c99e065bc)), closes [#675](https://github.com/expert-lsp/expert/issues/675)
* properly log when engine fails to initialize ([#244](https://github.com/expert-lsp/expert/issues/244)) ([81e1184](https://github.com/expert-lsp/expert/commit/81e118462c83e8298c6cb39631431c2f65a1edbf))
* properly set the mix env when building expert ([4caf258](https://github.com/expert-lsp/expert/commit/4caf2581ffa480aa87de70b6b9fef20207873414))
* **release:** don't cd into rel directory before starting app ([#268](https://github.com/expert-lsp/expert/issues/268)) ([3b76e97](https://github.com/expert-lsp/expert/commit/3b76e97539a10fcfdf6a6fd24bba7fedd54fca54))
* remove all usages of epmd ([#339](https://github.com/expert-lsp/expert/issues/339)) ([cef4adb](https://github.com/expert-lsp/expert/commit/cef4adb13bfb9e697892f421ebdd949b87c10084))
* remove erts from extra_applications ([#202](https://github.com/expert-lsp/expert/issues/202)) ([aa8bd84](https://github.com/expert-lsp/expert/commit/aa8bd84692222cfd763308815566d261430cd957))
* remove escape sequences from PATH in fish ([#237](https://github.com/expert-lsp/expert/issues/237)) ([b237fd5](https://github.com/expert-lsp/expert/commit/b237fd547a0bc3a34df2574b2d1c1fee47d1f2b6))
* Resolve doesn't recognize zero-arg defs as functions ([#606](https://github.com/expert-lsp/expert/issues/606)) ([38a649c](https://github.com/expert-lsp/expert/commit/38a649c7a6758c0c91dc350f0d7888a7b68017a6)), closes [#604](https://github.com/expert-lsp/expert/issues/604)
* resolve function delegates on hover docs ([#399](https://github.com/expert-lsp/expert/issues/399)) ([a3c629a](https://github.com/expert-lsp/expert/commit/a3c629a8e3cbabf2badd494695a614b2e8a389ae))
* revert "feat: epmdless deployments ([#167](https://github.com/expert-lsp/expert/issues/167))" ([#180](https://github.com/expert-lsp/expert/issues/180)) ([0f66faa](https://github.com/expert-lsp/expert/commit/0f66faa317fdbefd3aed407ce46c294d1f6bdec2))
* revert dev server ([#48](https://github.com/expert-lsp/expert/issues/48)) ([9345e31](https://github.com/expert-lsp/expert/commit/9345e31ea92da54c2124803223f8b50a08a53a00))
* sanitize node names ([#323](https://github.com/expert-lsp/expert/issues/323)) ([7591304](https://github.com/expert-lsp/expert/commit/7591304e94d3421db7788544fa7e8b382a393f6d))
* start projects after server is initialized ([#294](https://github.com/expert-lsp/expert/issues/294)) ([76d6cd5](https://github.com/expert-lsp/expert/commit/76d6cd5570232f5725456356c9c4d29e2db090d1))
* stop sending genlsp datastructures to engine ([#31](https://github.com/expert-lsp/expert/issues/31)) ([43d406f](https://github.com/expert-lsp/expert/commit/43d406f6d46faa396269f1c7adb9ccda3e94fa29))
* support Fish shell's space-separated PATH format ([#172](https://github.com/expert-lsp/expert/issues/172)) ([9803293](https://github.com/expert-lsp/expert/commit/9803293d4fe87ef1254b580b1e6aa0c833658edc))
* support mise et al on windows ([#304](https://github.com/expert-lsp/expert/issues/304)) ([3cc343f](https://github.com/expert-lsp/expert/commit/3cc343fd8dc63cd78be84f21a0aec6f8a5afc79d))
* support Nushell for PATH detection ([#272](https://github.com/expert-lsp/expert/issues/272)) ([8a9fd3d](https://github.com/expert-lsp/expert/commit/8a9fd3dbd3552a9378548807b5d13f306ec4a92e))
* trim any quotes wrapping PATH when elixir is managed by mise ([#82](https://github.com/expert-lsp/expert/issues/82)) ([d828966](https://github.com/expert-lsp/expert/commit/d82896631c986ae57bdff47a8906c3d7bcbb22c5))
* trim PATH returned by shell ([#213](https://github.com/expert-lsp/expert/issues/213)) ([735199d](https://github.com/expert-lsp/expert/commit/735199deac03fa8a9de0a992964e9f14a1a35a66))
* update document store on didchange even without the engine running ([#326](https://github.com/expert-lsp/expert/issues/326)) ([c80b72d](https://github.com/expert-lsp/expert/commit/c80b72d05d9ee8c04efde6402c65a552306bf07a))
* update gen_lsp to 0.11.3 ([#315](https://github.com/expert-lsp/expert/issues/315)) ([13cfee6](https://github.com/expert-lsp/expert/commit/13cfee67150d562e2f97bcf4a558946c2aafd7b6)), closes [#245](https://github.com/expert-lsp/expert/issues/245)
* update spitfire to v0.3.4 ([#373](https://github.com/expert-lsp/expert/issues/373)) ([6f57f16](https://github.com/expert-lsp/expert/commit/6f57f1648c61fd5deaa3212f385205f52696f6f3))
* update spitfire to v0.3.5 ([#376](https://github.com/expert-lsp/expert/issues/376)) ([85822fe](https://github.com/expert-lsp/expert/commit/85822fe7c7d32c47e47b211fb94c0493a35d0bf8))
* use Calendar.UTCOnlyTimeZoneDatabase instead of project configured tz database ([#324](https://github.com/expert-lsp/expert/issues/324)) ([9e913f6](https://github.com/expert-lsp/expert/commit/9e913f640ba31e3dd36f5615da2e6e68e10a5d2e))
* use correct build directory when namespacing expert ([b6540dd](https://github.com/expert-lsp/expert/commit/b6540ddffa210acd1ac03f9d7317f8baa3bcdc70))
* use dynamic registrations and start project node asynchronously ([#30](https://github.com/expert-lsp/expert/issues/30)) ([e1ce165](https://github.com/expert-lsp/expert/commit/e1ce1655e7354dae5206e42f4fc10f86ad347b90))
* use minimal PATH on unix instead of fully removing it ([#305](https://github.com/expert-lsp/expert/issues/305)) ([74da1a5](https://github.com/expert-lsp/expert/commit/74da1a568dd741fca381c9bb9019127556640a79))
* use project directory when building engine ([#203](https://github.com/expert-lsp/expert/issues/203)) ([c5ac441](https://github.com/expert-lsp/expert/commit/c5ac44164b69b0ec63d5f5b462c40ba787d9fe90))
* utf8_prefix should take into account empty lines ([#164](https://github.com/expert-lsp/expert/issues/164)) ([16c21e0](https://github.com/expert-lsp/expert/commit/16c21e087b1d6753e7fa46c13c67242c69a48e31))


### Miscellaneous Chores

* release as 0.1.0 ([7625d3c](https://github.com/expert-lsp/expert/commit/7625d3cb530897c02657837fad2b4116228346e9))
* release as 0.1.0-rc.0 ([c98b870](https://github.com/expert-lsp/expert/commit/c98b870fc073656cb955defda8b8623f71d2abc8))

## Unreleased
No changes yet
