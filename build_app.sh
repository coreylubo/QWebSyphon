#!/bin/bash
echo "Copying app skeleton... 🦴"
cp -r app_bundler/QWebSyphon.app.skeleton/ ./QWebSyphon.app

echo "Compiling binary... ⚙️"
swift build --arch arm64 --arch x86_64 --configuration release

echo "Copying binary and frameworks... 📦"
cp .build/apple/Products/Release/QWebSyphon ./QWebSyphon.app/Contents/MacOS
cp -r .build/apple/Products/Release/Syphon.framework/ ./QWebSyphon.app/Contents/Frameworks/Syphon.framework/

echo "Patching runtime path... 🔨"
install_name_tool -change @rpath/Syphon.framework/Versions/A/Syphon @executable_path/../Frameworks/Syphon.framework/Versions/A/Syphon ./QWebSyphon.app/Contents/MacOS/QWebSyphon

echo "Cleaning up... 🧹"
rm ./QWebSyphon.app/Contents/MacOS/.gitkeep 
rm ./QWebSyphon.app/Contents/Frameworks/.gitkeep 

echo "Done! ✅"