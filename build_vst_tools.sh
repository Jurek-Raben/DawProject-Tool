
mkdir ./ffx.tools.DawProject.xrnx/bin

# build vst2info-tool
cd vst2info-tool
cargo b -r
cp ./target/release/vst2info-tool ../ffx.tools.DawProject.xrnx/bin

cd ..
