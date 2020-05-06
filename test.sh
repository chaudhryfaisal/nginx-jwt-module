#!/usr/bin/env bash

RED='\033[01;31m'
GREEN='\033[01;32m'
YELLOW='\033[01;33m'
NONE='\033[00m'

USE_CURRENT=0

# use an already running container
if [[ "$1" == "--current" ]]; then
  USE_CURRENT=1
  DOCKER_CONTAINER_NAME=${2:-0}
  if [[ "$DOCKER_CONTAINER_NAME" == "0" ]]; then
    echo -e "${YELLOW}Warning: configuration tests needs the container identifier as second argument${NONE}"
  fi
# build test image if no image name passed
elif [ -z "$1" ]; then
  echo "Building test image from jwt-nginx"
  DOCKER_IMAGE_NAME=jwt-nginx-test
  cd test-image
  docker build -t ${DOCKER_IMAGE_NAME} .
  cd ..
  if [ $? -ne 0 ]
  then
    echo -e "${RED}Build Failed${NONE}";
    exit 1;
  fi
# use a specific image
else
  DOCKER_IMAGE_NAME=$1
  echo "Using image ${DOCKER_IMAGE_NAME} for tests"
  shift
fi

if [[ "$USE_CURRENT" == "0" ]]; then
  DOCKER_CONTAINER_NAME=container-${DOCKER_IMAGE_NAME}
  docker run --rm --name "${DOCKER_CONTAINER_NAME}" -d -p 8000:8000 ${DOCKER_IMAGE_NAME}
fi

if [[ "$OSTYPE" == "darwin"* ]] || [[ "$OSTYPE" == "linux"* ]]; then
  # Mac OSX / Linux
  MACHINE_IP='localhost'
else
  # Windows
  MACHINE_IP=`docker-machine ip 2> /dev/null`
fi


b64enc() { openssl enc -base64 -A | tr '+/' '-_' | tr -d '='; }
hs_sign() { openssl dgst -binary -sha"${1}" -hmac "$2"; }
rs_sign() { openssl dgst -binary -sha"${1}" -sign <(printf '%s\n' "$2"); }

make_jwt() {
  local alg=$1
  local key=$2
  local header=`echo -n "{\"alg\":\"$alg\"}" | b64enc`
  local payload=`echo -n '{}' | b64enc`
  local secret=`cat ./test-image/nginx/keys/$key`
  local sig=`echo -n "$header.$payload" | rs_sign '256' "$secret" | b64enc`
  echo -n "$header.$payload.$sig"
  return 0
}

VALID_RS256=`make_jwt RS256 rsa-private.pem`
BAD_RS256=`make_jwt RS256 rsa-wrong-private.pem`
VALID_JWT="eyJhbGciOiJIUzI1NiJ9.e30.-gVyhFDs5NeX0yvaAoTPVgrDfrg_qk7dF0sNj_-Bu-c"
BAD_SIG="eyJhbGciOiJIUzI1NiJ9.e30.nmwH1lIcnA-g8CEV_fWIlAV7h98_Wwy1gIqIabAdrIs"

test_for_tab () {
  local test=`grep $'\t' src/ngx_http_auth_jwt_fic_module.c | wc -l`
  local name='Indent test'
  if [ "$test" == "0" ];then
    echo -e "${GREEN}${name}: passed${NONE}";
  else
    echo -e "${RED}${name}: failed (found ${test} tabs instead of 0)${NONE}";
    exit 1
  fi
}

test_for_tab

test_jwt () {
  local name=$1
  local path=$2
  local expect=$3
  local extra=$4

  cmd="curl -X GET -o /dev/null --silent --head --write-out '%{http_code}' http://$MACHINE_IP:8000$path -H 'cache-control: no-cache' $extra"

  test=$( eval $cmd )
  if [ "$test" -eq "$expect" ];then
    echo -e "${GREEN}${name}: passed (${test})${NONE}";
  else
    echo -e "${RED}${name}: failed (${test} instead of ${expect})${NONE}";
  fi
}

test_conf () {
  local target=$DOCKER_CONTAINER_NAME
  local config=$1
  local expect="$2"

  match=`docker exec -it $target nginx -t -c "/etc/nginx/${config}.conf" | grep "$expect" | wc -l`

  if [ "$match" -ne "0" ];then
    echo -e "${GREEN}Config test ${config}: passed (${match})${NONE}";
  else
    echo -e "${RED}Config test ${config}: failed (no match for '${expect}')${NONE}";
  fi
}

test_jwt "Insecure test" "/" "200"

test_jwt "Secure test without jwt" "/secure-cookie/" "401"

test_jwt "Secure test without jwt" "/secure-auth-header/" "401"

test_jwt "Secure test with valid jwt cookie" "/secure-cookie/" "200" "--cookie \"rampartjwt=${VALID_JWT}\""

test_jwt "Secure test with bad cookie name" "/secure-cookie/" "401" "--cookie \"invalid_name=${VALID_JWT}\""

test_jwt "Secure test with invalid jwt cookie" "/secure-cookie/" "401" "--cookie \"rampartjwt=invalid\""

test_jwt "Secure test with valid jwt cookie but invalid signature" "/secure-cookie/" "401" "--cookie \"rampartjwt=${BAD_SIG}\""

test_jwt "Secure test with valid jwt cookie but expecting auth header" "/secure-cookie/" "401" "--header \"Authorization: Bearer ${VALID_JWT}\""

test_jwt "Secure test with valid jwt auth header but expecting cookie" "/secure-cookie/" "401" "--header \"Authorization: Bearer ${VALID_JWT}\""

test_jwt "Secure test with valid jwt auth header" "/secure-auth-header/" "200" "--header \"Authorization: Bearer ${VALID_JWT}\""

test_jwt "Secure test with valid jwt auth header but invalid signature" "/secure-auth-header/" "401" "--header \"Authorization: Bearer ${BAD_SIG}\""

test_jwt "Secure test with invalid jwt auth header" "/secure-auth-header/" "401" "--header \"Authorization: x\""

test_jwt "Secure test with invalid jwt auth header" "/secure-auth-header/" "401" "--header \"Authorization: Beare\""

test_jwt "Secure test with invalid jwt auth header" "/secure-auth-header/" "401" "--header \"Authorization: Bearer\""

test_jwt "Secure test with invalid jwt auth header" "/secure-auth-header/" "401" "--header \"Authorization: BearerXa\""

test_jwt "Secure test with invalid jwt auth header" "/secure-auth-header/" "401" "--header \"Authorization: BearAr a\""

test_jwt "Secure test with valid jwt cookie - RS256" "/rsa-file-encoded/" "200" "--header \"Authorization: Bearer ${VALID_RS256}\""

test_jwt "Secure test with invalid jwt cookie - RS256" "/rsa-file-encoded/" "401" "--header \"Authorization: Bearer ${BAD_RS256}\""

test_jwt "Secure test with valid jwt on restricted algoritm - RS256" "/restricted-alg/" "200" "--header \"Authorization: Bearer ${VALID_RS256}\""

test_jwt "Secure test with valid jwt on non-restricted algoritm: expect RS256" "/any-alg/" "200" "--header \"Authorization: Bearer ${VALID_RS256}\""

test_jwt "Secure test with valid jwt but invalid algoritm on restricted algoritm: expect RS256" "/restricted-alg/" "401" "--header \"Authorization: Bearer ${VALID_JWT}\""

test_jwt "Secure test with valid jwt on restricted algoritm: expect HS256" "/restricted-alg-2/" "200" "--header \"Authorization: Bearer ${VALID_JWT}\""

test_jwt "Secure test with valid jwt but invalid algoritm on restricted algoritm: expect HS256" "/restricted-alg-2/" "401" "--header \"Authorization: Bearer ${VALID_RS256}\""

test_jwt "Secure test with valid jwt cookie, and unused cookies" "/secure-cookie/" "200" "--cookie \"rampartjwt=${VALID_JWT}; session=${VALID_JWT}\""

if [[ "$DOCKER_CONTAINER_NAME" == "0" ]]; then
  echo -e "${YELLOW}Warning: container identifier not set -> skipping configuration tests${NONE}"
  exit 1
fi

test_conf 'invalid-nginx' '"auth_jwt_fic_key" directive is duplicate in /etc/nginx/invalid-nginx.conf:18'

test_conf 'invalid-arg-1' 'invalid number of arguments in "auth_jwt_fic" directive in /etc/nginx/invalid-arg-1.conf:6'

test_conf 'invalid-arg-2' 'invalid number of arguments in "auth_jwt_fic_key" directive in /etc/nginx/invalid-arg-2.conf:5'

test_conf 'invalid-arg-3' 'Invalid key in /etc/nginx/invalid-arg-3.conf:5'

test_conf 'invalid-arg-4' 'No such file or directory (2: No such file or directory) in /etc/nginx/invalid-arg-4.conf:5'

test_conf 'invalid-arg-5' 'No such file or directory (2: No such file or directory) in /etc/nginx/invalid-arg-5.conf:5'

test_conf 'invalid-key-1' 'Failed to turn hex key into binary in /etc/nginx/invalid-key-1.conf:5'

test_conf 'invalid-key-2' 'Failed to turn base64 key into binary in /etc/nginx/invalid-key-2.conf:5'

if [[ "$USE_CURRENT" == "0" ]]; then
  echo stopping container $DOCKER_CONTAINER_NAME
  docker stop ${DOCKER_CONTAINER_NAME} > /dev/null
fi
