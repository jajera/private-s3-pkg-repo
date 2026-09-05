# Rebuild Lambda container: createrepo_c + apt-ftparchive + Python handler.
# Built and pushed by demo.sh up-shared; EventBridge triggers on .rpm/.deb Put.
#
#   aws ecr create-repository --repository-name ps3p-rebuild
#   docker build -t ps3p-rebuild lambda/rebuild
#   docker tag … && docker push …
#   aws lambda create-function --package-type Image ...
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LAMBDA_TASK_ROOT=/var/task

RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      python3 python3-pip \
      createrepo-c apt-utils ca-certificates curl gzip gnupg \
 && rm -rf /var/lib/apt/lists/* \
 && pip3 install --break-system-packages --no-cache-dir awslambdaric boto3

COPY app.py ${LAMBDA_TASK_ROOT}/app.py
WORKDIR ${LAMBDA_TASK_ROOT}

ENTRYPOINT ["python3", "-m", "awslambdaric"]
CMD ["app.handler"]
