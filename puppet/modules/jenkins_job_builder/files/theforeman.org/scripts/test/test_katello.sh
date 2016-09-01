#!/bin/bash -e

database=postgresql
ruby=2.2

if [ "${branch}" == "KATELLO-3.2" ]; then
  foreman_branch='1.13-stable'
elif [ "${branch}" == "KATELLO-3.1" ]; then
  foreman_branch='1.12-stable'
else
  foreman_branch='develop'
fi

rm -rf foreman/
git clone https://github.com/theforeman/foreman --branch "${foreman_branch}"

TOP_ROOT=`pwd`
APP_ROOT=$TOP_ROOT/foreman
PLUGIN_ROOT=$TOP_ROOT/plugin

### Foreman PR testing ###
cd $APP_ROOT
if [ -n "${foreman_pr_git_url}" ]; then
  git remote add pr ${foreman_pr_git_url}
  git fetch pr
  git merge pr/${foreman_pr_git_ref}
fi

### PR testing ###
cd $PLUGIN_ROOT
if [ -n "${pr_git_url}" ]; then
  git remote add pr ${pr_git_url}
  git fetch pr
  git merge pr/${pr_git_ref}
fi

cd $APP_ROOT
mkdir config/settings.plugins.d

# setup basic settings file
sed -e 's/:locations_enabled: false/:locations_enabled: true/' $APP_ROOT/config/settings.yaml.example > $APP_ROOT/config/settings.yaml
sed -i 's/:organizations_enabled: false/:organizations_enabled: true/' $APP_ROOT/config/settings.yaml

# RVM Ruby environment
. /etc/profile.d/rvm.sh
# Use a gemset unique to each executor to enable parallel builds
gemset=$(echo ${JOB_NAME} | cut -d/ -f1)-${EXECUTOR_NUMBER}
rvm use ruby-${ruby}@${gemset} --create
rvm gemset empty --force
gem update --no-ri --no-rdoc
gem install bundler --no-ri --no-rdoc

# Now let's introduce the plugin
echo "gemspec :path => '${PLUGIN_ROOT}', :development_group => :katello_dev" >> bundler.d/Gemfile.local.rb

# Retry as rubygems (being external to us) can be intermittent
while ! bundle update -j 5; do
  (( c += 1 ))
  if [ $c -ge 5 ]; then
    echo "bundle update continually failed" >&2
    exit 1
  fi
done

# Database environment
(
  sed "s/^test:/development:/; s/database:.*/database: ${gemset}-dev/" $HOME/${database}.db.yaml
  echo
  sed "s/database:.*/database: ${gemset}-test/" $HOME/${database}.db.yaml
) > $APP_ROOT/config/database.yml

# Create DB first in development as migrate behaviour can change
cd $APP_ROOT
bundle exec rake db:drop db:create
### END test_develop ###

# Now let's add the plugin migrations
cd $APP_ROOT
bundle exec rake db:migrate

# Rubocop
echo "**** Running Rubocop ****"
cd $APP_ROOT
bundle exec rake katello:rubocop:jenkins TESTOPTS="-v" --trace

# Test UI
echo "**** Running UI Tests ****"
cd $PLUGIN_ROOT/engines/bastion_katello
bastion_install=`bundle show bastion`
cp -rf $bastion_install .
bastion_version=(${bastion_install//bastion-/ })
npm install bastion-${bastion_version[1]} grunt
bundle exec rake bastion:ci -t

# Katello-specific tests
echo "**** Running Unit Tests *****"
cd $APP_ROOT
bundle exec rake jenkins:katello TESTOPTS="-v"

# Test asset precompile
echo "**** Running Asset Precompile *****"
cd $APP_ROOT
bundle exec rake plugin:assets:precompile[katello] --trace

echo "**** Building and Archiving Gem *****"
cd $PLUGIN_ROOT
rm -rf pkg/
mkdir pkg
gem build katello.gemspec
cp katello-*.gem pkg/
