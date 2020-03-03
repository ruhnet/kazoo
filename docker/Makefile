ROOT ?= $(shell cd "$(dirname '.')" && cd .. && pwd -P)
DOCKER_ROOT ?= ${ROOT}/docker

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


PROFILE_DIRS = $(sort $(dir $(wildcard $(DOCKER_ROOT)/profiles/*/)))
PROFILES = $(foreach dir,$(PROFILE_DIRS),$(shell basename $(dir)))

START_TARGETS = $(addprefix docker-start,$(PROFILES))

define make-target
	$(addprefix $1-,$(PROFILES))
endef

UP_TARGETS = $(call make-target,docker-up)
DOWN_TARGETS = $(call make-target,docker-down)
PS_TARGETS = $(call make-target,docker-ps)

.PHONY: docker-env \
		docker-list-profiles \
		$(UP_TARGETS) \
		$(DOWN_TARGETS) \
		$(PS_TARGETS)

# Enviroment

export ROOT
export DOCKER_ROOT

KAZOO_SRC ?= ${ROOT}
export KAZOO_SRC


# this is good for use with `eval` and export containers ports and urls
docker-env:
	@echo
	@cat ${DOCKER_ROOT}/banner.txt
	@echo
	@echo "export ROOT=${ROOT}"
	@echo "export DOCKER_ROOT=${DOCKER_ROOT}"
	@echo "export KAZOO_SRC=${KAZOO_SRC}"

docker-list-profiles:
	@echo $(PROFILES) | tr ' ' '\n'


$(UP_TARGETS): docker-up-%:
	docker-compose -f ${DOCKER_ROOT}/profiles/$*/docker-compose.yml up -d

$(DOWN_TARGETS): docker-down-%:
	docker-compose -f ${DOCKER_ROOT}/profiles/$*/docker-compose.yml down

$(PS_TARGETS): docker-ps-%:
	docker-compose -f ${DOCKER_ROOT}/profiles/$*/docker-compose.yml ps
