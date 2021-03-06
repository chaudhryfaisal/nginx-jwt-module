#!/usr/bin/env bash

RED='\033[01;31m'
NONE='\033[00m'

# example usage: ./build [--compress]

# build main image
DOCKER_IMAGE_NAME=jwt-nginx
docker build -t ${DOCKER_IMAGE_NAME} $@ .
if [ $? -ne 0 ]
then
  echo -e "${RED}Build Failed${NONE}";
  exit 1;
fi

# # Copy newly generated module in the repository
# JWT_MODULE=ngx_http_auth_jwt_fic_module.so
# docker run ${DOCKER_IMAGE_NAME} cat /usr/lib/nginx/modules/${JWT_MODULE} > ${JWT_MODULE}
