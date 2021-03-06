#!/usr/bin/env bash
set -e
set -x

export GHE_USERNAME="dev1"
export GHE_EMAIL="jenkins-x@googlegroups.com"

# fix broken `BUILD_NUMBER` env var
export BUILD_NUMBER="$BUILD_ID"

JX_HOME="/tmp/jxhome"
KUBECONFIG="/tmp/jxhome/config"

# lets avoid the git/credentials causing confusion during the test
export XDG_CONFIG_HOME=$JX_HOME

mkdir -p $JX_HOME/git

jx install dependencies --all

jx --version

# replace the credentials file with a single user entry
echo "https://$GHE_USERNAME:$GHE_ACCESS_TOKEN@github.beescloud.com" > $JX_HOME/git/credentials

gcloud auth activate-service-account --key-file $GKE_SA

# lets setup git 
git config --global --add user.name JenkinsXBot
git config --global --add user.email jenkins-x@googlegroups.com

echo "running the BDD tests with JX_HOME = $JX_HOME"

# setup jx boot parameters
export JX_VALUE_ADMINUSER_PASSWORD="$JENKINS_PASSWORD"
export JX_VALUE_PIPELINEUSER_USERNAME="$GHE_USERNAME"
export JX_VALUE_PIPELINEUSER_EMAIL="$GHE_EMAIL"
export JX_VALUE_PIPELINEUSER_TOKEN="$GHE_ACCESS_TOKEN"
export JX_VALUE_PROW_HMACTOKEN="$GHE_ACCESS_TOKEN"

# TODO temporary hack until the batch mode in jx is fixed...
export JX_BATCH_MODE="true"

# Push the snapshot chart
pushd charts/lighthouse
make snapshot
popd

rm -rf boot-source
# Use the latest boot config promoted in the version stream instead of master to avoid conflicts during boot, because
# boot fetches always the latest version available in the version stream.
git clone  https://github.com/jenkins-x/jenkins-x-versions.git versions
export BOOT_CONFIG_VERSION=$(jx step get dependency-version --host=github.com --owner=jenkins-x --repo=jenkins-x-boot-config --dir versions | sed 's/.*: \(.*\)/\1/')
git clone https://github.com/jenkins-x/jenkins-x-boot-config.git boot-source
cd boot-source
git checkout tags/v${BOOT_CONFIG_VERSION} -b latest-boot-config

cp ../bdd/ghe/jx-requirements.yml .
cp ../bdd/ghe/parameters.yaml env

# Manually interpolate lighthouse version tag
cat ../bdd/values.yaml.template >> env/lighthouse/values.tmpl.yaml
cp env/lighthouse/values.tmpl.yaml values.tmpl.yaml.tmp
sed 's/$VERSION/'"$VERSION"'/' values.tmpl.yaml.tmp > env/lighthouse/values.tmpl.yaml
cat env/lighthouse/values.tmpl.yaml
rm values.tmpl.yaml.tmp
sed -e s/\$VERSION/${VERSION}/g ../bdd/helm-requirements.yaml.template > env/requirements.yaml

echo "Building lighthouse with version $VERSION"

# TODO hack until we fix boot to do this too!
helm init --client-only
helm repo add jenkins-x https://storage.googleapis.com/chartmuseum.jenkins-x.io

export BDD_ENABLE_TEST_CHATOPS_COMMANDS="true"

# Enable checking the commit status reporting URL
export BDD_LIGHTHOUSE_BASE_REPORT_URL=https://example.com

set +e
jx step bdd \
    --versions-repo https://github.com/jenkins-x/jenkins-x-versions.git \
    --config ../bdd/ghe/cluster.yaml \
    --gopath /tmp \
    --git-provider=github \
    --git-provider-url https://github.beescloud.com \
    --git-username $GHE_USERNAME \
    --git-api-token $GHE_ACCESS_TOKEN \
    --default-admin-password $JENKINS_PASSWORD \
    --no-delete-app \
    --no-delete-repo \
    --tests install \
    --tests test-lighthouse

bdd_result=$?
if [[ $bdd_result != 0 ]]; then
  pushd ..
  bash bdd/capture-failed-pod-logs.sh
  popd
fi
cd ../charts/lighthouse
make delete-from-chartmuseum

exit $bdd_result
