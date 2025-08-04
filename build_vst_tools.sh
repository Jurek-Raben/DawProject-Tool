
mkdir ./ffx.tools.DawProject.xrnx/bin

# build vst2info-tool
cd vst2info-tool

if [[ "$OSTYPE" == "darwin"* ]]; then
cargo b -r  --target=x86_64-apple-darwin --target=aarch64-apple-darwin
#lipo -create \
#  -output target/vst2info-tool \
#  target/x86_64-apple-darwin/release/vst2info-tool \
#  target/aarch64-apple-darwin/release/vst2info-tool
#cp ./target/vst2info-tool ../ffx.tools.DawProject.xrnx/bin/vst2info-tool-mac
cp ./target/x86_64-apple-darwin/release/vst2info-tool ../ffx.tools.DawProject.xrnx/bin/vst2info-tool-mac-x64
cp ./target/aarch64-apple-darwin/release/vst2info-tool ../ffx.tools.DawProject.xrnx/bin/vst2info-tool-mac-arm

cargo b -r  --target=x86_64-pc-windows-gnu
cp ./target/x86_64-pc-windows-gnu/release/vst2info-tool.exe ../ffx.tools.DawProject.xrnx/bin/vst2info-tool-win.exe

CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=x86_64-unknown-linux-gnu-gcc \
cargo b -r --target=x86_64-unknown-linux-gnu
cp ./target/x86_64-unknown-linux-gnu/release/vst2info-tool ../ffx.tools.DawProject.xrnx/bin/vst2info-tool-linux
fi

if [[ "$OSTYPE" == "win32"* ]]; then
cargo b -r
cp ./target/release/vst2info-tool ../ffx.tools.DawProject.xrnx/bin/vst2info-tool-win.exe
fi

if [[ "$OSTYPE" == "linux-gnu"* ]]; then
cargo b -r
cp ./target/release/vst2info-tool ../ffx.tools.DawProject.xrnx/bin/vst2info-tool-linux
fi

cd ..



# build vst2info-tool
cd vst3info-tool

if [[ "$OSTYPE" == "darwin"* ]]; then
cargo b -r  --target=x86_64-apple-darwin --target=aarch64-apple-darwin
cp ./target/x86_64-apple-darwin/release/vst3info-tool ../ffx.tools.DawProject.xrnx/bin/vst3info-tool-mac-x64
cp ./target/aarch64-apple-darwin/release/vst3info-tool ../ffx.tools.DawProject.xrnx/bin/vst3info-tool-mac-arm

fi

cd ..