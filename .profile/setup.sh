#!bash

echo RUN SETUP SCRIPT FOR /workspaces/$RepositoryName/

# add setup here!
source .bashrc
nohup bash /workspaces/$RepositoryName/.profile/auto-commit-all.sh &
echo FINSIHED!
