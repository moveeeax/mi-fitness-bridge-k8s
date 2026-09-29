IMAGE ?= ghcr.io/moveeeax/mi-fitness-bridge
TAG   ?= latest
NS    ?= mi-fitness
CTX   ?= admin@talos-nbg1-tarassov-me
KUBECTL = kubectl --context $(CTX) -n $(NS)

.PHONY: basic-auth deploy status logs db-pull rollout

# Basic auth for the ingress: mcp-proxy has no auth of its own.
basic-auth:
	@test -n "$(USER_NAME)" || (echo "USER_NAME=... PASSWORD=... make basic-auth" && exit 1)
	@python3 -c "import base64,hashlib,os;u=os.environ['USER_NAME'];p=os.environ['PASSWORD'];print(u+':{SHA}'+base64.b64encode(hashlib.sha1(p.encode()).digest()).decode())" > auth.htpasswd
	kubectl --context $(CTX) -n $(NS) create secret generic mi-fitness-basic-auth \
		--from-file=auth=auth.htpasswd --dry-run=client -o yaml | kubectl --context $(CTX) apply -f -
	@rm -f auth.htpasswd

deploy:
	cd k8s && kustomize edit set image $(IMAGE):$(TAG) || true
	kubectl --context $(CTX) apply -k k8s/

status:
	$(KUBECTL) get pvc,cronjob,deploy,pod,ingress

logs:
	$(KUBECTL) logs -l app.kubernetes.io/component=mcp --tail=100 -f

rollout:
	$(KUBECTL) rollout restart deploy/mi-fitness-mcp

# Pull the SQLite cache down for local analysis (the MCP server keeps running).
db-pull:
	$(KUBECTL) cp $$($(KUBECTL) get pod -l app.kubernetes.io/component=mcp -o name | head -1 | cut -d/ -f2):/data/mi_fitness.db ./mi_fitness.db
