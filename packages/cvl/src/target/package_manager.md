```
ui_pkg := package_manager[
    .url = "<url>",
    .hash = "<hash>",
];
ui := #import: ui_pkg.path: "main.cvl";
cpp_pkg := package_manager[
    .url = "<url>",
    .hash = "<hash>",
    .has_lockfile = false,
    // ^ when this is set, it uses the package hash as its id
    //    and a version of 0.0.0
    // if not set, it will search for that information in the lockfile
];

package_manager := std.package_manager[
    .name = "my_package_name",
    .version = "1.0.0",
    .id = "<uuid>",
    // ^ this stuff gets saved to the lockfile

    // the lockfile will only be updated when the flag `--update-lockfile` is passed on the cli
    // (typically that would be done using an arg passed
    // to std.build. does with_env handle that??)
    .lockfile = "cvl.lock",

    .require_all_urls_overridden = .true,
    .url_overrides = [
        "<hash>" = "url",
    ],
];

std.build = package_manager.with_env: (target) {
    // ...
    std.build.compile(target): {
        ui.example();
    };
};
```

```
{
    // contains all packages, even lazy dependencies
    "all_packages": {
        "<hash>": ["id", "version", ...dependency_ids],
    },
    "download_urls": {
        "<hash>": ["url1", "url2"],
    },
    
}
```

to use the package manager, a lockfile must be set in the
comptime env. (without a lockfile set, packages you include
won't have their packages downloaded correctly)

what happens if you set the package manager env but just
for one package?

how much would it propagate?

```
ui_pkg := with_env: package;
import: ui_pkg.path: "abc" <- that won't work
because the import will import the file with the global env

then worst case it has its own with_env set and it tries to
```

it would be nice to not have the potential for the lockfile problem
