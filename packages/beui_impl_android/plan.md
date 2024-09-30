plan:

- depend on android_template
- to build an android app, run `zig build android` from your repository. this will copy the android template in at `platform/android/`. then, open android studio on that folder and build the app.
- all android builds go through android studio
- as much as possible, the android studio template app just calls into code from beui_impl_android. there is
  as little code as possible in the android template app. if you don't make any changes, to update it you can
  just delete it and remake it. if you do make changes, you'll have to update it manually.
- this package will contain any generic code for the android stuff

ideally it wouldn't be like this and we could build normally with -Dbackend=android and it would emit an apk or aap. if we want that, then we need <https://github.com/ikskuh/ZigAndroidTemplate> or <https://github.com/silbinarywolf/zig-android-sdk> + documentation on how to set up the needed system dependencies and how to run an emulator and how to run on device ... etc. android studio is nice because you install an app, open a folder, wait a little while for a loading bar, and click run.