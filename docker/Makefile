
.PHONY: docker-amqp-db-start \
		docker-amqp-db-stop \
		docker-amqp-db-inspect \
		docker-amqp-db-down \
		docker-kzdev-amqp-db-start \
		docker-kzdev-amqp-db-stop \
		docker-kzdev-amqp-db-inspect

docker-kzdev-amqp-db-down:
ROOT ?= $(shell cd "$(dirname '.')" && pwd -P)
DOCKER_ROOT ?= ${ROOT}/docker
COMPOSE_DIR = ${DOCKER_ROOT}/compose

## Platform detection.
ifeq ($(PLATFORM),)
    UNAME_S := $(shell uname -s)

    ifeq ($(UNAME_S),Linux)
        PLATFORM = linux
    else ifeq ($(UNAME_S),Darwin)
        PLATFORM = darwin
    else
        $(error Unable to detect platform.)
    endif

    export PLATFORM
endif

# Enviroment

export ROOT
export DOCKER_ROOT

KAZOO_SRC ?= ${ROOT}
export KAZOO_SRC


#------------------------------------------------------------
# good for use with `eval`
#-----------------------------------------------------------+
docker-env:
	@cat ${DOCKER_ROOT}/banner.txt
	@echo
	@echo "export ROOT=${ROOT}"
	@echo "export DOCKER_ROOT=${DOCKER_ROOT}"
	@echo "export KAZOO_SRC=${KAZOO_SRC}"

#------------------------------------------------------------
## RabbitMQ + CouchDB + MailCatcher
#-----------------------------------------------------------+
docker-amqp-db-start:
	docker-compose -f ${COMPOSE_DIR}/kzmaster-amqp-db/docker-compose.yml up -d

docker-amqp-db-stop:
	docker-compose -f ${COMPOSE_DIR}/kzmaster-amqp-db/docker-compose.yml stop

docker-amqp-db-inspect:
	docker-compose -f ${COMPOSE_DIR}/kzmaster-amqp-db/docker-compose.yml inspect

docker-amqp-db-down:
	docker-compose -f ${COMPOSE_DIR}/kzmaster-amqp-db/docker-compose.yml down


#------------------------------------------------------------
# Kazoo Dev + Kazoo-sounds + RabbitMQ + CouchDB + MailCatcher
#-----------------------------------------------------------+
docker-kzdev-amqp-db-start:
	docker-compose -f ${COMPOSE_DIR}/kzmaster-kzdev-amqp-db/docker-compose.yml up -d

docker-kzdev-amqp-db-stop:
	docker-compose -f ${COMPOSE_DIR}/kzmaster-kzdev-amqp-db/docker-compose.yml stop

docker-kzdev-amqp-db-inspect:
	docker-compose -f ${COMPOSE_DIR}/kzmaster-kzdev-amqp-db/docker-compose.yml inspect

docker-kzdev-amqp-db-down:
	docker-compose -f ${COMPOSE_DIR}/kzmaster-kzdev-amqp-db/docker-compose.yml down
