
### anti-slop

Oxlint rules that catch specific coding mistakes in JavaScript and TypeScript projects (array `filter().map()` chains, widening then asserting types, `Reflect.get`, object-shaped parameters, `typeof` at runtime, and more), so the agent fixes them. Source: [dmmulroy/anti-slop](https://github.com/dmmulroy/anti-slop) (MIT). Skill: `install-anti-slop`.

The plugin is built from the pinned source and shipped with the pack. Run it in any project:

```console
$ anti-slop                 # lint the current directory with every anti-slop rule
$ anti-slop src/ --fix      # any oxlint arguments work
$ anti-slop -c my.json .    # use your own oxlint config instead of the built-in one
```

`anti-slop` runs oxlint from nixpkgs and loads the plugin from the Nix store through oxlint's `jsPlugins`, so it works offline and needs no `pnpm add`. The upstream `install-anti-slop` skill instead copies the plugin into a repository and installs `oxlint` and `@oxlint/plugins` from npm; use that when the project should own and customise the rules. The plugin is pinned upstream against oxlint 1.78.0, and nixpkgs may carry a different oxlint version.
