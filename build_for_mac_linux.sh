cd ./ffx.tools.DawProject.xrnx
rm ../build/ffx.tools.DawProject.xrnx
zip -r ../build/ffx.tools.DawProject.xrnx . -x "./tmp/*" "/.github/*" "/.git/*" "/.vscode/*" "./examples/*" "./tmp/*" "./config.json" ".DS_Store" ".gitignore"
