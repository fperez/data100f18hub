#!/bin/bash
# vim: set et sw=4 ts=4:
set -euo pipefail

# This script is used by travis to trigger deployments or builds

# .travis.yml:
# - AZ_LOCATION
# - CLUSTER_ADMIN
# - DOCKER_PASSWORD (secure)
# - DOCKER_USERNAME (secure)
# - HUB_COURSE
# - SUBSCRIPTION_PREFIX
# travis project settings:
# - encrypted_76378860b24f_key (created by 'travis encrypt-file')
# - encrypted_76378860b24f_iv  (created by 'travis encrypt-file')

function prepare_azure {
    SP="${TRAVIS_BUILD_DIR}/hub/secrets/sp-${TRAVIS_BRANCH}.json"
    if [ ! -f ${SP} ]; then
		echo "Could not find service principal file: ${SP}"
		echo find ${TRAVIS_BUILD_DIR}
		find ${TRAVIS_BUILD_DIR}
		exit 1
	fi

    if ! jq -r . ${SP} > /dev/null 2>&1 ; then
        echo "Could not lint azure service principal file."
        md5sum ${SP}
        exit 1
    fi

    az login --service-principal \
              -u $(jq -r .name     ${SP}) \
              -p $(jq -r .password ${SP}) \
        --tenant $(jq -r .tenant   ${SP}) > /dev/null
    az account set -s ${SUBSCRIPTION_PREFIX}-${TRAVIS_BRANCH} > /dev/null
}

function build {
    echo "Starting build..."
    PUSH=''

    if [[ ${TRAVIS_PULL_REQUEST} == 'false' ]]; then
        PUSH='--push'
        # Assume we have secrets!
        docker login -u $DOCKER_USERNAME -p "$DOCKER_PASSWORD"
    fi

    # Attempt to improve relability of pip installs:
    # https://github.com/travis-ci/travis-ci/issues/2389
    sudo sysctl net.ipv4.tcp_ecn=0

    echo ./deploy.py build --commit-range ${TRAVIS_COMMIT_RANGE} ${PUSH}
    ./deploy.py build --commit-range ${TRAVIS_COMMIT_RANGE} ${PUSH}
}

function unlock_repo {
    # Encrypted variables are only set when we are not a PR
    # https://docs.travis-ci.com/user/pull-requests/#Pull-Requests-and-Security-Restrictions
    echo "Fetching git-crypt key..."
    openssl aes-256-cbc \
        -K $encrypted_76378860b24f_key \
        -iv $encrypted_76378860b24f_iv \
        -in git-crypt.key.enc -out ./git-crypt.key -d

    chmod 0400 git-crypt.key

    if [ $(head -1 git-crypt.key 2>/dev/null | cut -c2-12) != "GITCRYPTKEY" ];
    then
        echo Could not decrypt git-crypt.key.enc.
        exit 1
    fi

    echo "Unlocking repository..."
    git-crypt unlock git-crypt.key
}

function deploy {
    echo "Starting deploy..."
    REPO="https://github.com/${TRAVIS_REPO_SLUG}"
    COMMIT="${TRAVIS_COMMIT}"

    # we are on azure
    if [ "$TRAVIS_BRANCH" == "prod" ]; then
        AZ_LOCATION=westus2
    fi

    unlock_repo

    export KUBECONFIG="${TRAVIS_BUILD_DIR}/hub/secrets/kc-${TRAVIS_BRANCH}.${AZ_LOCATION}.json"

    prepare_azure

    echo ./deploy.py deploy ${TRAVIS_BRANCH}
    ./deploy.py deploy ${TRAVIS_BRANCH}

    echo "Done!"
}

# main
case $1 in
    build)  build ;;
    deploy) deploy ;;
esac
