MKFILE_PATH := $(abspath $(lastword $(MAKEFILE_LIST)))
PROJECT_PATH := $(patsubst %/,%,$(dir $(MKFILE_PATH)))

# VERSION defines the project version for the bundle.
# Update this value when you upgrade the version of your project.
# To re-generate a bundle for another specific version without changing the standard setup, you can:
# - use the VERSION as arg of the bundle target (e.g make bundle VERSION=0.0.2)
# - use environment variables to overwrite this value (e.g export VERSION=0.0.2)
VERSION ?= 0.0.1

# CHANNELS define the bundle channels used in the bundle.
# Add a new line here if you would like to change its default config. (E.g CHANNELS = "candidate,fast,stable")
# To re-generate a bundle for other specific channels without changing the standard setup, you can:
# - use the CHANNELS as arg of the bundle target (e.g make bundle CHANNELS=candidate,fast,stable)
# - use environment variables to overwrite this value (e.g export CHANNELS="candidate,fast,stable")
ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif

# DEFAULT_CHANNEL defines the default channel used in the bundle.
# Add a new line here if you would like to change its default config. (E.g DEFAULT_CHANNEL = "stable")
# To re-generate a bundle for any other default channel without changing the default setup, you can:
# - use the DEFAULT_CHANNEL as arg of the bundle target (e.g make bundle DEFAULT_CHANNEL=stable)
# - use environment variables to overwrite this value (e.g export DEFAULT_CHANNEL="stable")
ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)

# IMAGE_TAG_BASE defines the docker.io namespace and part of the image name for remote images.
# This variable is used to construct full image tags for bundle and catalog images.
#
# For example, running 'make bundle-build bundle-push catalog-build catalog-push' will build and push both
# quay.io/kuadrant/kuadrant-controller-bundle:$VERSION and quay.io/kuadrant/kuadrant-controller-catalog:$VERSION.
IMAGE_TAG_BASE ?= quay.io/kuadrant/kuadrant-controller

# BUNDLE_IMG defines the image:tag used for the bundle.
# You can use it as an arg. (E.g make bundle-build BUNDLE_IMG=<some-registry>/<project-name-bundle>:<tag>)
BUNDLE_IMG ?= $(IMAGE_TAG_BASE)-bundle:v$(VERSION)

# Image URL to use all building/pushing image targets
DEFAULT_IMG ?= $(IMAGE_TAG_BASE):latest
IMG ?= $(DEFAULT_IMG)
# ENVTEST_K8S_VERSION refers to the version of kubebuilder assets to be downloaded by envtest binary.
ENVTEST_K8S_VERSION = 1.22

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# Setting SHELL to bash allows bash commands to be executed by recipes.
# This is a requirement for 'setup-envtest.sh' in the test target.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

KIND_CLUSTER_NAME = kuadrant-local
GOLANGCI-LINT = $(PROJECT_PATH)/bin/golangci-lint

all: build

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-30s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development

manifests: controller-gen ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	$(CONTROLLER_GEN) rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases
	$(MAKE) deploy-manifest

.PHONY: deploy-manifest
deploy-manifest: kustomize ## Generate deployment manifests.
	mkdir -p $(PROJECT_DIR)/config/deploy
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(IMG)
	$(KUSTOMIZE) build config/default > $(PROJECT_DIR)/config/deploy/manifests.yaml
	# clean up
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(DEFAULT_IMG)

generate: controller-gen ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

fmt: ## Run go fmt against code.
	go fmt ./...

vet: ## Run go vet against code.
	go vet ./...

test: test-unit test-integration ## Run all tests

test-integration: clean-cov generate fmt vet manifests envtest ## Run Integration tests.
	KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) -p path)" USE_EXISTING_CLUSTER=true go test ./... -coverprofile $(PROJECT_PATH)/cover.out -tags integration -ginkgo.v -ginkgo.progress -v -timeout 0

test-unit: clean-cov generate fmt vet ## Run Unit tests.
	go test ./... -coverprofile $(PROJECT_PATH)/cover.out -tags unit -v -timeout 0

clean-cov:
	rm -rf $(PROJECT_PATH)/cover.out

.PHONY: local-setup
local-setup: local-cleanup local-setup-kind manifests kustomize generate ## Deploy locally kuadrant controller from the current code
	export PATH=$(PROJECT_PATH)/bin:$$PATH;	./utils/local-deployment/local-setup.sh


# kuadrant is not deployed
.PHONY: local-env-setup
local-env-setup: local-cleanup local-setup-kind deploy-kuadrant-deps generate install ## Deploys all services and manifests required by kuadrant to run. Used to run kuadrant with "make run"

.PHONY: deploy-kuadrant-deps
deploy-kuadrant-deps:
	./utils/local-deployment/deploy-kuadrant-deps.sh

.PHONY: local-setup-kind
local-setup-kind: kind
	$(KIND) create cluster --name $(KIND_CLUSTER_NAME) --config utils/local-deployment/kind-cluster.yaml

.PHONY: local-cleanup
local-cleanup: kind
	$(KIND) delete cluster --name $(KIND_CLUSTER_NAME)

.PHONY: run-lint
run-lint: $(GOLANGCI-LINT) ## Run lint tests
	$(GOLANGCI-LINT) run

ISTIO_MANIFEST_PATH = $(PROJECT_DIR)/utils/local-deployment/istio-manifests/autogenerated
.PHONY: generate-istio-manifests
generate-istio-manifests: istioctl ## Generates istio manifests with patches.
	-rm -rf $(ISTIO_MANIFEST_PATH)
	mkdir -p $(ISTIO_MANIFEST_PATH)
	$(ISTIOCTL) manifest generate --set profile=minimal --set values.gateways.istio-ingressgateway.autoscaleEnabled=false --set values.pilot.autoscaleEnabled=false --set values.global.istioNamespace=$(KUADRANT_NAMESPACE) -f utils/local-deployment/patches/istio-externalProvider.yaml -o $(ISTIO_MANIFEST_PATH)

.PHONY: istio-manifest-update-test
istio-manifest-update-test: generate-istio-manifests ## Test istio manifest
	git diff --exit-code $(ISTIO_MANIFEST_PATH)
	[ -z "$$(git ls-files --other --exclude-standard --directory --no-empty-directory $(ISTIO_MANIFEST_PATH))" ]

GATEWAYAPI_MANIFEST_PATH = $(PROJECT_DIR)/utils/local-deployment/gatewayapi-manifests/autogenerated
.PHONY: generate-gwapi-manifests
generate-gwapi-manifests:  ## Generates Gateway API manifests
	-rm -rf $(GATEWAYAPI_MANIFEST_PATH)
	mkdir -p $(GATEWAYAPI_MANIFEST_PATH)
	kubectl kustomize "github.com/kubernetes-sigs/gateway-api/config/crd?ref=v0.4.0" > $(GATEWAYAPI_MANIFEST_PATH)/Base.yaml

.PHONY: gwapi-manifests-update-test
gwapi-manifests-update-test: generate-gwapi-manifests ## Test Gateway API manifests
	git diff --exit-code $(GATEWAYAPI_MANIFEST_PATH)
	[ -z "$$(git ls-files --other --exclude-standard --directory --no-empty-directory $(GATEWAYAPI_MANIFEST_PATH))" ]


.PHONY: manifests-update-test
manifests-update-test: manifests ## Test autogenerated controller manifests
	git diff --exit-code ./config
	[ -z "$$(git ls-files --other --exclude-standard --directory --no-empty-directory ./config)" ]

LIMITADOR_OPERATOR_SCM_VERSION=main
LIMITADOR_OPERATOR_IMAGE_TAG=latest
LIMITADOR_OPERATOR_IMAGE=quay.io/kuadrant/limitador-operator:$(LIMITADOR_OPERATOR_IMAGE_TAG)
.PHONY: generate-limitador-manifests
generate-limitador-manifests: ## Generates limitador manifests.
	$(eval TMP := $(shell mktemp -d))
	cd $(TMP); git clone --depth 1 --branch $(LIMITADOR_OPERATOR_SCM_VERSION) https://github.com/kuadrant/limitador-operator.git
	cd $(TMP)/limitador-operator; make kustomize
	cd $(TMP)/limitador-operator/config/manager; $(TMP)/limitador-operator/bin/kustomize edit set image controller=$(LIMITADOR_OPERATOR_IMAGE)
	cd $(TMP)/limitador-operator/config/default; $(TMP)/limitador-operator/bin/kustomize edit set namespace $(KUADRANT_NAMESPACE)
	cd $(TMP)/limitador-operator; bin/kustomize build config/default -o $(PROJECT_PATH)/utils/local-deployment/limitador-operator.yaml
	-rm -rf $(TMP)

##@ Build

build: generate fmt vet ## Build manager binary.
	go build -o bin/manager main.go

run: export LOG_LEVEL = debug
run: export LOG_MODE = development
run: manifests generate fmt vet ## Run a controller from your host.
	go run ./main.go

docker-build: ## Build docker image with the manager.
	docker build -t ${IMG} .

docker-push: ## Push docker image with the manager.
	docker push ${IMG}

# old
manager: build

##@ Deployment

install: manifests kustomize ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

uninstall: manifests kustomize ## Uninstall CRDs from the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | kubectl delete -f -

deploy: manifests kustomize ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default | kubectl apply -f -

undeploy: ## Undeploy controller from the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/default | kubectl delete -f -

CONTROLLER_GEN = $(shell pwd)/bin/controller-gen
controller-gen: ## Download controller-gen locally if necessary.
	$(call go-get-tool,$(CONTROLLER_GEN),sigs.k8s.io/controller-tools/cmd/controller-gen@v0.8.0)

KUSTOMIZE = $(shell pwd)/bin/kustomize
kustomize: ## Download kustomize locally if necessary.
	$(call go-get-tool,$(KUSTOMIZE),sigs.k8s.io/kustomize/kustomize/v4@v4.5.2)

ENVTEST = $(shell pwd)/bin/setup-envtest
envtest: ## Download envtest-setup locally if necessary.
	$(call go-get-tool,$(ENVTEST),sigs.k8s.io/controller-runtime/tools/setup-envtest@latest)

OPERATOR_SDK = $(shell pwd)/bin/operator-sdk
OPERATOR_SDK_VERSION = v1.22.0
operator-sdk: ## Download operator-sdk locally if necessary.
	./utils/install-operator-sdk.sh $(OPERATOR_SDK) $(OPERATOR_SDK_VERSION)

# go-get-tool will 'go get' any package $2 and install it to $1.
PROJECT_DIR := $(shell dirname $(abspath $(lastword $(MAKEFILE_LIST))))
define go-get-tool
@[ -f $(1) ] || { \
set -e ;\
TMP_DIR=$$(mktemp -d) ;\
cd $$TMP_DIR ;\
go mod init tmp ;\
echo "Downloading $(2)" ;\
GOBIN=$(PROJECT_DIR)/bin go install $(2) ;\
rm -rf $$TMP_DIR ;\
}
endef

.PHONY: bundle
bundle: manifests kustomize ## Generate bundle manifests and metadata, then validate generated files.
	operator-sdk generate kustomize manifests -q
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(IMG)
	$(KUSTOMIZE) build config/manifests | operator-sdk generate bundle -q --overwrite --version $(VERSION) $(BUNDLE_METADATA_OPTS)
	operator-sdk bundle validate ./bundle

.PHONY: bundle-build
bundle-build: ## Build the bundle image.
	docker build -f bundle.Dockerfile -t $(BUNDLE_IMG) .

.PHONY: bundle-push
bundle-push: ## Push the bundle image.
	$(MAKE) docker-push IMG=$(BUNDLE_IMG)

.PHONY: opm
OPM = ./bin/opm
opm: ## Download opm locally if necessary.
ifeq (,$(wildcard $(OPM)))
ifeq (,$(shell which opm 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p $(dir $(OPM)) ;\
	OS=$(shell go env GOOS) && ARCH=$(shell go env GOARCH) && \
	curl -sSLo $(OPM) https://github.com/operator-framework/operator-registry/releases/download/v1.15.1/$${OS}-$${ARCH}-opm ;\
	chmod +x $(OPM) ;\
	}
else
OPM = $(shell which opm)
endif
endif

# A comma-separated list of bundle images (e.g. make catalog-build BUNDLE_IMGS=example.com/operator-bundle:v0.1.0,example.com/operator-bundle:v0.2.0).
# These images MUST exist in a registry and be pull-able.
BUNDLE_IMGS ?= $(BUNDLE_IMG)

# The image tag given to the resulting catalog image (e.g. make catalog-build CATALOG_IMG=example.com/operator-catalog:v0.2.0).
CATALOG_IMG ?= $(IMAGE_TAG_BASE)-catalog:v$(VERSION)

# Set CATALOG_BASE_IMG to an existing catalog image tag to add $BUNDLE_IMGS to that image.
ifneq ($(origin CATALOG_BASE_IMG), undefined)
FROM_INDEX_OPT := --from-index $(CATALOG_BASE_IMG)
endif

# Build a catalog image by adding bundle images to an empty catalog using the operator package manager tool, 'opm'.
# This recipe invokes 'opm' in 'semver' bundle add mode. For more information on add modes, see:
# https://github.com/operator-framework/community-operators/blob/7f1438c/docs/packaging-operator.md#updating-your-existing-operator
.PHONY: catalog-build
catalog-build: opm ## Build a catalog image.
	$(OPM) index add --container-tool docker --mode semver --tag $(CATALOG_IMG) --bundles $(BUNDLE_IMGS) $(FROM_INDEX_OPT)

# Push the catalog image.
.PHONY: catalog-push
catalog-push: ## Push a catalog image.
	$(MAKE) docker-push IMG=$(CATALOG_IMG)

##@ Misc

## Miscellaneous Custom targets

KUADRANT_NAMESPACE=kuadrant-system

KIND = $(shell pwd)/bin/kind
kind: ## Download kind locally if necessary.
	$(call go-get-tool,$(KIND),sigs.k8s.io/kind@v0.11.1)

$(GOLANGCI-LINT):
	curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $(PROJECT_PATH)/bin v1.46.1

.PHONY: golangci-lint
golangci-lint: $(GOLANGCI-LINT) ## Download golangci-lint locally if necessary.

# istioctl tool
ISTIOCTL=$(PROJECT_PATH)/bin/istioctl
ISTIOVERSION = 1.12.1
$(ISTIOCTL):
	mkdir -p $(PROJECT_PATH)/bin
	$(eval TMP := $(shell mktemp -d))
	cd $(TMP); curl -sSL https://istio.io/downloadIstio | ISTIO_VERSION=$(ISTIOVERSION) sh -
	cp $(TMP)/istio-$(ISTIOVERSION)/bin/istioctl ${ISTIOCTL}
	-rm -rf $(TMP)

.PHONY: istioctl
istioctl: $(ISTIOCTL) ## Download istioctl locally if necessary.
