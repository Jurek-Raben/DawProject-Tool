
mkdir ./ffx.tools.DawProject.xrnx/bin

# build vst2info-tool
cd vst2info-tool
cargo b -r
if [[ "$OSTYPE" == "darwin"* ]]; then
cp ./target/release/vst2info-tool ../ffx.tools.DawProject.xrnx/bin/vst2info-tool-mac-$(uname -m)
fi

if [[ "$OSTYPE" == "win32"* ]]; then
cp ./target/release/vst2info-tool ../ffx.tools.DawProject.xrnx/bin/vst2info-tool-win-$(uname -m).exe
fi

if [[ "$OSTYPE" == "linux-gnu"* ]]; then
cp ./target/release/vst2info-tool ../ffx.tools.DawProject.xrnx/bin/vst2info-tool-linux-$(uname -m)
fi

cd ..
