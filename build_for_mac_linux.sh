
# pack renoise tool
cd ./ffx.tools.DawProject.xrnx
rm ../build/ffx.tools.DawProject.xrnx
#zip -r ../build/ffx.tools.DawProject.xrnx . -x "./tmp/*" "/.github/*" "/.git/*" "/.vscode/*" "./examples/*" "./tmp/*" "./config.json" ".DS_Store" ".gitignore"
tar -acvf ../build/ffx.tools.DawProject.zip --exclude="./tmp" --exclude="/.github" --exclude="/.git" --exclude="/.vscode" --exclude="./examples" --exclude="./tmp" --exclude="./config.json" *
mv ../build/ffx.tools.DawProject.zip ../build/ffx.tools.DawProject.xrnx
