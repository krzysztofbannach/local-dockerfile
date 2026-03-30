ARG REPOSITORY=256120352618.dkr.ecr.us-east-1.amazonaws.com/dok-cicd-registry
ARG IMAGE=library/ubuntu:22.04
ARG OPERATORS_DOK_3RD_PARTY_IMAGE=dok-3rd-party:0.0.12-20250731-084101
ARG GOLANG_IMAGE=golang:1.25
ARG ALPINE_IMAGE=alpine:3.19
ARG K9S_VERSION=v0.50.16
ARG POPEYE_VERSION=v0.22.1
ARG KUBECOLOR_VERSION=v0.0.25
ARG CONTROLLER_GEN_VERSION=v0.19.0
ARG DELVE_VERSION=v1.25.2
ARG HELM_VERSION=v4.0.1
ARG JQ_IMAGE=ghcr.io/jqlang/jq:1.8.1
ARG YQ_IMAGE=mikefarah/yq:4.46.1
ARG MOCKGEN_VERSION=v1.5.0
ARG KIND_VERSION=v0.30.0
ARG KUBEBUILDER_VERSION=v4.11.1
ARG HELM_DOCS_VERSION=latest
ARG KUBECTL_VERSION=1.34.2
ARG KUBELOGIN_VERSION=0.2.13
ARG KUTTL_VERSION=0.24.0

FROM $GOLANG_IMAGE AS golang_base

FROM $ALPINE_IMAGE AS alpine_base
RUN apk add --no-cache curl unzip

FROM golang_base AS k9s_builder
ARG K9S_VERSION
RUN git clone https://github.com/derailed/k9s.git
RUN cd k9s && git checkout $K9S_VERSION && make build

FROM golang_base AS popeye_builder
ARG POPEYE_VERSION
RUN git clone https://github.com/derailed/popeye
RUN cd popeye && git checkout $POPEYE_VERSION && go install

FROM golang_base AS tfenv_builder
RUN git clone --depth=1 https://github.com/tfutils/tfenv.git /usr/.tfenv

FROM golang_base AS kubecolor_builder
ARG KUBECOLOR_VERSION
RUN go install github.com/hidetatz/kubecolor/cmd/kubecolor@$KUBECOLOR_VERSION

FROM golang_base AS goimports_builder
RUN go install golang.org/x/tools/cmd/goimports@latest

FROM golang_base AS controller_gen_builder
ARG CONTROLLER_GEN_VERSION
RUN go install sigs.k8s.io/controller-tools/cmd/controller-gen@$CONTROLLER_GEN_VERSION

FROM golang_base AS mockgen_builder
ARG MOCKGEN_VERSION
RUN go install github.com/golang/mock/mockgen@$MOCKGEN_VERSION

FROM golang_base AS govulncheck_builder
RUN go install golang.org/x/vuln/cmd/govulncheck@latest

FROM golang_base AS delve_builder
ARG DELVE_VERSION
RUN git clone https://github.com/go-delve/delve
RUN cd delve && git checkout $DELVE_VERSION && go install github.com/go-delve/delve/cmd/dlv

FROM golang_base AS helm_builder
ARG HELM_VERSION
RUN git clone https://github.com/helm/helm.git /opt/helm
RUN cd /opt/helm && git checkout $HELM_VERSION && make

FROM golang_base AS kind_builder
ARG KIND_VERSION
RUN go install sigs.k8s.io/kind@$KIND_VERSION

FROM golang_base AS kubebuilder_builder
ARG KUBEBUILDER_VERSION
RUN go install sigs.k8s.io/kubebuilder/v4@$KUBEBUILDER_VERSION

FROM golang_base AS helm_docs_builder
ARG HELM_DOCS_VERSION
RUN go install github.com/norwoodj/helm-docs/cmd/helm-docs@$HELM_DOCS_VERSION

FROM alpine_base AS kubectl_builder
ARG KUBECTL_VERSION
RUN curl -fsSLo /usr/bin/kubectl "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
 && chmod +x /usr/bin/kubectl

FROM alpine_base AS kubelogin_builder
ARG KUBELOGIN_VERSION
RUN curl -fsSLo /tmp/kubelogin.zip "https://github.com/Azure/kubelogin/releases/download/v${KUBELOGIN_VERSION}/kubelogin-linux-amd64.zip" \
 && unzip -q /tmp/kubelogin.zip -d /tmp \
 && mv /tmp/bin/linux_amd64/kubelogin /usr/bin/kubelogin \
 && chmod +x /usr/bin/kubelogin \
 && rm -rf /tmp/kubelogin.zip /tmp/bin

FROM alpine_base AS kuttl_builder
ARG KUTTL_VERSION
RUN curl -fsSLo /usr/bin/kuttl "https://github.com/kudobuilder/kuttl/releases/download/v${KUTTL_VERSION}/kubectl-kuttl_0.24.0_linux_x86_64" \
 && chmod +x /usr/bin/kuttl

FROM $JQ_IMAGE AS jq_image

FROM $YQ_IMAGE AS yq_image

#FROM golang:1.13 AS stern_builder
#RUN #apt update && apt upgrade -y && apt install -y govendor
#RUN mkdir -p $GOPATH/src/github.com/stern && \
#	cd $GOPATH/src/github.com/stern && \
#	git clone https://github.com/stern/stern.git && cd stern && \
##	govendor sync && \
#	go install

#FROM golang:1.16 AS kail_builder
#RUN apt update && apt upgrade -y && apt install -y govendor
#RUN go get -d github.com/boz/kail && cd /go/pkg/mod/github.com/boz/kail@v0.15.0 && make install-deps && make

FROM alpine/git AS kubectx_builder
RUN git clone https://github.com/ahmetb/kubectx /opt/kubectx

FROM hadolint/hadolint:v1.9.0 AS hadolint_builder

# TODO kbannach needed?
#FROM $REPOSITORY/$IMAGE AS cicd-builder-sources
#RUN apt update && apt install -y git && apt clean
#COPY .ssh/ /root/.ssh/
#RUN chmod 700 /root/.ssh && chmod 600 /root/.ssh/* && chmod 644 /root/.ssh/*.pub
#RUN git clone git@github.com:dynatrace-infrastructure/dok-cicd-builder.git

# TODO spróbować zamienić pobieranie całego image na
#   zainstalowanie Go klasycznie
#   zainstalowanie envtest przez sklonowanie repo 3rd-party i odpalenie make perpare-test
FROM $REPOSITORY/$OPERATORS_DOK_3RD_PARTY_IMAGE AS operators-dok-3rd-party

FROM $REPOSITORY/$IMAGE
ARG AWSCLI_VERSION="2.17.5"
ARG GOLANGCI_LINT_VERSION="v1.62.2"
ARG GOSEC_VERSION="v2.22.10"
ARG DEBIAN_FRONTEND=noninteractive

# Include prebuilt operators' dependencies in the builder image
COPY --from=operators-dok-3rd-party /var/opt/envtest/testbin /var/opt/envtest/testbin
COPY --from=operators-dok-3rd-party /go /root/go

# TODO kbannach needed?
COPY --from=256120352618.dkr.ecr.us-east-1.amazonaws.com/dok-cicd-registry/library/dok-python:0.0.1-20230310-080711 /python_3.9.13-1_amd64.deb /opt/

# TODO kbannach needed?
#COPY --from=cicd-builder-sources /dok-cicd-builder/building /tmp/building
#COPY --from=cicd-builder-sources /dok-cicd-builder/applications /tmp/applications

COPY --from=hadolint_builder /bin/hadolint /usr/local/bin/hadolint

COPY --from=tfenv_builder /usr/.tfenv /usr/.tfenv
ENV PATH="/usr/.tfenv/bin:${PATH}:/root/go/bin"

COPY --from=delve_builder /go/bin/dlv /usr/bin/dlv
COPY --from=helm_builder /opt/helm/bin/helm /usr/bin/helm

COPY --from=popeye_builder /go/bin/popeye /usr/bin
RUN chmod +x /usr/bin/popeye
#COPY --from=stern_builder /go/bin/stern /usr/bin
#RUN chmod +x /usr/bin/stern
#COPY --from=kail_builder /go/pkg/mod/github.com/boz/kail@v0.15.0/kail /usr/bin
#RUN chmod +x /usr/bin/kail
COPY --from=kubectx_builder /opt/kubectx/kubectx /usr/bin
COPY --from=kubectx_builder /opt/kubectx/kubens /usr/bin
RUN chmod +x /usr/bin/kubectx
RUN chmod +x /usr/bin/kubens

COPY --from=k9s_builder /go/k9s/execs/k9s /usr/bin/k9s_bare
RUN chmod +x /usr/bin/k9s_bare
#RUN mkdir -p /root/.config/k9s
#RUN touch /root/.config/k9s/config.yml
#RUN chown dok /home/dok/.config/k9s
#RUN chown dok /home/dok/.config/k9s/config.yml
#RUN echo "sed -i \"s/nodeShell: false/nodeShell: true/g\" /home/dok/.config/k9s/config.yml && /usr/bin/k9s_bare " > /usr/bin/k9s && chmod +x /usr/bin/k9s
#RUN echo "sed -i \"s/nodeShell: false/nodeShell: true/g\" /root/.config/k9s/config.yml && /usr/bin/k9s_bare " > /usr/bin/k9s && chmod +x /usr/bin/k9s
RUN cp /usr/bin/k9s_bare /usr/bin/k9s && chmod +x /usr/bin/k9s

COPY --from=jq_image /jq /usr/local/bin/jq
COPY --from=yq_image /usr/bin/yq /usr/local/bin/yq

###################### main apt install ######################
RUN apt update && apt install -y build-essential wget curl unzip bash-completion lsb-release libcap2-bin unzip vim git-all software-properties-common gettext && apt clean
RUN add-apt-repository -y ppa:deadsnakes/ppa && apt update && apt install -y python3.12 && apt clean && ln -s /usr/bin/python3.12 /usr/bin/python
RUN curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py && python get-pip.py

RUN wget https://github.com/tmccombs/hcl2json/releases/download/v0.6.4/hcl2json_linux_amd64
RUN mv hcl2json_linux_amd64 /usr/bin/hcl2json
RUN chmod +x /usr/bin/hcl2json

COPY --from=golang_base /usr/local/go /usr/local/go
ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH="/opt/go"
ENV PATH="${PATH}:${GOPATH}/bin"

# binary will be $(go env GOPATH)/bin/golangci-lint
RUN curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $(go env GOPATH)/bin ${GOLANGCI_LINT_VERSION}

#RUN curl -sfL https://raw.githubusercontent.com/securego/gosec/master/install.sh | sh -s -- -b $(go env GOPATH)/bin ${GOSEC_VERSION} #TODO kbannach

COPY aws/awscli_public.key /root/building/awscli_public.key
RUN gpg --import /root/building/awscli_public.key
RUN curl -fsSLo awscliv2.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip
RUN curl -fsSLo awscliv2.sig https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip.sig
RUN gpg --verify awscliv2.sig awscliv2.zip
RUN unzip -q awscliv2.zip
RUN ./aws/install

RUN wget -O /tmp/gcloudcli.tgz https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz
RUN tar -C /usr/local -xf /tmp/gcloudcli.tgz
RUN /usr/local/google-cloud-sdk/install.sh --quiet
ENV PATH="/usr/local/google-cloud-sdk/bin:${PATH}"
RUN gcloud components install gke-gcloud-auth-plugin --quiet

#RUN useradd \
#    --create-home \
#    --home /home/dok \
#    --shell /bin/sh \
#    dok

ARG TERRAFORM_VERSION=1.13.1
RUN tfenv install ${TERRAFORM_VERSION}; tfenv use ${TERRAFORM_VERSION}

COPY --from=kubecolor_builder /go/bin/kubecolor /usr/bin/kubecolor
RUN echo 'alias k=kubecolor' >>~/.bashrc
#RUN echo 'complete -F __start_kubectl k' >>~/.bashrc
#RUN echo 'complete -o default -F __start_kubectl k' >>~/.bashrc
RUN echo "alias kccc='k config current-context'" >> ~/.bashrc
RUN echo "alias kcgc='k config get-contexts'" >> ~/.bashrc
RUN echo "alias kcuc='k config use-context'" >> ~/.bashrc
RUN echo "alias tf='terraform'" >> ~/.bashrc
RUN echo "alias gisoft='git reset --soft '" >> ~/.bashrc

RUN wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
RUN gpg --no-default-keyring --keyring /usr/share/keyrings/hashicorp-archive-keyring.gpg --fingerprint
RUN echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list
RUN apt update && apt install -y vault && apt clean
RUN chmod +x /usr/bin/vault
RUN setcap -r /usr/bin/vault
ENV VAULT_ADDR="http://localhost:8200"

COPY --from=goimports_builder /go/bin/goimports /usr/bin/goimports
COPY --from=controller_gen_builder /go/bin/controller-gen /usr/bin/controller-gen
COPY --from=kind_builder /go/bin/kind /usr/bin/kind
COPY --from=kubebuilder_builder /go/bin/kubebuilder /usr/bin/kubebuilder
COPY --from=helm_docs_builder /go/bin/helm-docs /usr/bin/helm-docs
COPY --from=mockgen_builder /go/bin/mockgen /usr/bin/mockgen
COPY --from=govulncheck_builder /go/bin/govulncheck /usr/bin/govulncheck
COPY --from=kubectl_builder /usr/bin/kubectl /usr/bin/kubectl
COPY --from=kubelogin_builder /usr/bin/kubelogin /usr/bin/kubelogin
COPY --from=kuttl_builder /usr/bin/kuttl /usr/bin/kuttl
RUN pip install pre-commit

RUN mkdir -p /usr/share/terraform/plugins; terraform providers mirror /usr/share/terraform/plugins; rm -rf /tmp/*;

RUN curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && chmod +x /tmp/get-docker.sh && sh /tmp/get-docker.sh

ENV KUBECONFIG="/root/workspace/kubeconfig"

RUN git config --global user.email "krzysztof.bannach@dynatrace.com"; \
    git config --global user.name "Krzysztof Bannach"; \
    git config --global --add safe.directory '*'; \
    git config --global url."git@git.dynalabs.io:".insteadOf "https://git.dynalabs.io/"; \
    git config --global url."git@github.com:".insteadOf "https://github.com/"

COPY ./.ssh /root/.ssh
RUN chmod 700 /root/.ssh
RUN chmod 600 /root/.ssh/*
RUN chmod 644 /root/.ssh/*.pub

ENV GOPROXY="https://proxy.golang.org,direct"
ENV GOPRIVATE="git.dynalabs.io/dok/*,github.com/dynatrace-infrastructure/*,bitbucket.lab.dynatrace.org/*"

RUN curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /etc/apt/trusted.gpg.d/microsoft.gpg
RUN echo "deb [arch=$(dpkg --print-architecture)] https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/azure-cli.list
#RUN add-apt-repository "deb [arch=$(dpkg --print-architecture)] https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main"
RUN apt update && apt install -y azure-cli && apt clean

#ARG CONTAINER_USERNAME="gl0x"
# add DoK user
#RUN useradd -rm -d /home/${CONTAINER_USERNAME} -s /bin/bash -g root -G sudo -u 1001 ${CONTAINER_USERNAME}
#RUN echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
#USER ${CONTAINER_USERNAME}
#WORKDIR /home/${CONTAINER_USERNAME}

#USER dok
#WORKDIR /home/dok
WORKDIR /root/

SHELL ["/bin/bash", "-o", "pipefail", "-cxe"]