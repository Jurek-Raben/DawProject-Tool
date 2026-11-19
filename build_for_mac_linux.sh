
# pack renoise tool
cd ./ffx.tools.DawProject.xrnx
rm ../build/ffx.tools.DawProject.xrnx
# zip follows the symlink lib/shared and packs the files themselves, so no -y here
zip -r ../build/ffx.tools.DawProject.xrnx . -x "./tmp/*" "/.github/*" "/.git/*" "/.vscode/*" "./examples/*" "./tmp/*" "./config.json" ".DS_Store" ".gitignore"
#tar -acvf ../build/ffx.tools.DawProject.zip --exclude="./tmp" --exclude="/.github" --exclude="/.git" --exclude="/.vscode" #--exclude="./examples" --exclude="./tmp" --exclude="./config.json" *
#mv ../build/ffx.tools.DawProject.zip ../build/ffx.tools.DawProject.xrnx

# pack the plugin migrator, zip also follows its symlink bin to the binaries of the DAW Project Tool
cd ../ffx.tools.PluginMigrator.xrnx
rm ../build/ffx.tools.PluginMigrator.xrnx
zip -r ../build/ffx.tools.PluginMigrator.xrnx . -x "./tmp/*" "./config.json" ".DS_Store" ".gitignore"
