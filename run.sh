#!/bin/bash
set -e

args=("$@")
if [ $# -ne 2 ]
then
  echo "Usage: `basename $0` build_type build_ref"
  echo "eg. `basename $0` experimental master"
  exit 2
fi

DATE=$(date +%Y%m%d%H%M%S)
BUILD_TYPE=$1
FLAPJACK_BUILD_REF=$2
# FIXME: Find this from lib/flapjack/version.rb
FLAPJACK_BUILD_TAG='1.0.0~rc3'

docker run -i -t -e "FLAPJACK_BUILD_REF=${FLAPJACK_BUILD_REF}" \
-e "FLAPJACK_PACKAGE_VERSION=${FLAPJACK_BUILD_TAG}~${DATE}-${FLAPJACK_BUILD_REF}" \
flapjack/omnibus-ubuntu bash -c \
"cd omnibus-flapjack ; \
git pull ; \
bundle install --binstubs ; \
bin/omnibus build --log-level=info flapjack"

container_id=`docker ps -l -q`
docker cp ${container_id}:/omnibus-flapjack/pkg .
docker rm ${container_id}

exit 0

# Check if awscli exists
if not hash aws 2>/dev/null; then
  apt-get install -y awscli
fi

# Check if aptly exists
if not hash aptly 2>/dev/null; then
  if [ -f /etc/debian_version ]; then
    echo 'deb http://repo.aptly.info/ squeeze main' > /etc/apt/sources.list.d/aptly.list
    gpg --keyserver keys.gnupg.net --recv-keys 2A194991
    gpg -a --export 2A194991 | apt-key add -

    apt-get update
    apt-get install -y aptly

    if !apt-get install -y aptly ; then
      echo "Error installing aptly." ; exit $? ;
    fi

    # Create aptly config file
    cat << EOF > aptly.conf
{
  "rootDir": "${PWD}/aptly",
  "downloadConcurrency": 4,
  "downloadSpeedLimit": 0,
  "architectures": [],
  "dependencyFollowSuggests": false,
  "dependencyFollowRecommends": false,
  "dependencyFollowAllVariants": false,
  "dependencyFollowSource": false,
  "gpgDisableSign": false,
  "gpgDisableVerify": false,
  "downloadSourcePackages": false,
  "S3PublishEndpoints": {}
}
EOF
  fi
fi
# End aptly installation

# Put packages into aptly repo, sync with S3
mkdir -p aptly
aws s3 sync s3://packages.flapjack.io/aptly aptly --acl private --region us-east-1

# Create the repo if it doesn't exist
if ! aptly -config=aptly.conf repo show flapjack-${BUILD_TYPE} 2>/dev/null ; then
  aptly -config=aptly.conf repo create --distribution ${BUILD_TYPE} flapjack-${BUILD_TYPE}
fi


if ! aptly -config=aptly.conf repo add flapjack-${BUILD_TYPE} pkg/flapjack_${FLAPJACK_BUILD_TAG}-${date}-${FLAPJACK_BUILD_REF}.deb ; then
  echo "Error adding deb to repostory" ; exit $? ;
fi

# Try updating the published repository, otherwise do the first publish
if ! aptly -config=aptly.conf -gpg-key="803709B6" publish update ${BUILD_TYPE} ; then
  aptly -config=aptly.conf -gpg-key="803709B6" publish repo flapjack-${BUILD_TYPE}
fi

aws s3 sync aptly s3://packages.flapjack.io/aptly --acl private --region us-east-1

aws s3 sync aptly/public s3://packages.flapjack.io/public --acl public-read --region us-east-1
