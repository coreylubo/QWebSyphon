#!/bin/bash
echo "Copying app skeleton... 🦴"
rm -rf ./QWebSyphon.app
cp -r app_bundler/QWebSyphon.app.skeleton/ ./QWebSyphon.app

echo "Compiling binary... ⚙️"
swift build --arch arm64 --arch x86_64 --configuration release

echo "Copying binary and frameworks... 📦"
cp .build/apple/Products/Release/QWebSyphon ./QWebSyphon.app/Contents/MacOS
# ditto keeps the framework's Versions/Current symlinks (cp -r flattens them, which breaks signing)
ditto .build/apple/Products/Release/Syphon.framework ./QWebSyphon.app/Contents/Frameworks/Syphon.framework

echo "Patching runtime path... 🔨"
install_name_tool -change @rpath/Syphon.framework/Versions/A/Syphon @executable_path/../Frameworks/Syphon.framework/Versions/A/Syphon ./QWebSyphon.app/Contents/MacOS/QWebSyphon

echo "Cleaning up... 🧹"
rm -f ./QWebSyphon.app/Contents/MacOS/.gitkeep
rm -f ./QWebSyphon.app/Contents/Frameworks/.gitkeep

echo "Signing (ad hoc)... ✍️"
# install_name_tool invalidates the linker's signature; Apple silicon won't run it unsigned
codesign --force --deep --sign - ./QWebSyphon.app

echo "Done! ✅"