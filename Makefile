.PHONY: all create destroy create-cluster-one create-cluster-two destroy-cluster-one destroy-cluster-two \
	submariner-deploy submariner-status \
	cnpg-deploy-cluster-one cnpg-deploy-cluster-two cnpg-deploy cnpg-status cnpg-test cnpg-delete \
	show_entries add_entry

INSTALLER := /Users/skozlov/.local/bin/openshift-install
ENV_FILE := .env
HUB_KUBECONFIG := cluster-one/auth/kubeconfig

all: create

create: create-cluster-one create-cluster-two

destroy: destroy-cluster-one destroy-cluster-two

create-cluster-one:
	@echo "=== Creating cluster-one (us-east-2) ==="
	@cd cluster-one && set -a && source ../$(ENV_FILE) && set +a && \
		$(INSTALLER) create cluster --log-level=info 2>&1 | tee install.log

create-cluster-two:
	@echo "=== Creating cluster-two (us-west-2) ==="
	@cd cluster-two && set -a && source ../$(ENV_FILE) && set +a && \
		$(INSTALLER) create cluster --log-level=info 2>&1 | tee install.log

destroy-cluster-one:
	@echo "=== Destroying cluster-one ==="
	@cd cluster-one && set -a && source ../$(ENV_FILE) && set +a && \
		$(INSTALLER) destroy cluster --log-level=info 2>&1 | tee destroy.log

destroy-cluster-two:
	@echo "=== Destroying cluster-two ==="
	@cd cluster-two && set -a && source ../$(ENV_FILE) && set +a && \
		$(INSTALLER) destroy cluster --log-level=info 2>&1 | tee destroy.log

# ========== Submariner Deployment ==========

submariner-deploy:
	@echo "=== Deploying Submariner with Globalnet mode ==="
	@if [ -z "$$AWS_ACCESS_KEY_ID" ] || [ -z "$$AWS_SECRET_ACCESS_KEY" ]; then \
		echo "ERROR: Run 'source .env' first"; exit 1; fi
	KUBECONFIG=$(HUB_KUBECONFIG) envsubst < manifests/secrets/local-cluster-aws-creds.yaml | kubectl apply -f -
	KUBECONFIG=$(HUB_KUBECONFIG) envsubst < manifests/secrets/cluster-two-aws-creds.yaml | kubectl apply -f -
	KUBECONFIG=$(HUB_KUBECONFIG) kubectl apply -k manifests/

submariner-status:
	@echo "=== Submariner Status ==="
	KUBECONFIG=$(HUB_KUBECONFIG) kubectl get managedclusteraddon -A | grep submariner || true
	@echo ""
	KUBECONFIG=cluster-one/auth/kubeconfig kubectl get gateway -n submariner-operator 2>/dev/null || true
	KUBECONFIG=cluster-two/auth/kubeconfig kubectl get gateway -n submariner-operator 2>/dev/null || true

# ========== CNPG Cross-Site Deployment ==========

CLUSTER_ONE_KUBECONFIG := cluster-one/auth/kubeconfig
CLUSTER_TWO_KUBECONFIG := cluster-two/auth/kubeconfig

cnpg-deploy: cnpg-deploy-cluster-one cnpg-deploy-cluster-two

cnpg-deploy-cluster-one:
	@echo "=== Deploying CNPG Operator and Base Resources on Cluster-One ==="
	KUBECONFIG=$(CLUSTER_ONE_KUBECONFIG) kubectl apply -f cnpg-cross-site/base/namespace.yaml
	KUBECONFIG=$(CLUSTER_ONE_KUBECONFIG) kubectl apply -f cnpg-cross-site/base/subscription.yaml
	@echo "Waiting for CNPG operator CSV to be installed..."
	@for i in $$(seq 1 60); do \
		CSV=$$(KUBECONFIG=$(CLUSTER_ONE_KUBECONFIG) kubectl get csv -n openshift-operators -o name 2>/dev/null | grep cloudnative-pg); \
		if [ -n "$$CSV" ]; then \
			echo "Found CSV: $$CSV"; \
			KUBECONFIG=$(CLUSTER_ONE_KUBECONFIG) kubectl wait --for=jsonpath='{.status.phase}'=Succeeded $$CSV -n openshift-operators --timeout=300s; \
			break; \
		fi; \
		echo "Waiting for CSV... ($$i/60)"; \
		sleep 5; \
	done
	@echo "Deploying CNPG Primary cluster..."
	KUBECONFIG=$(CLUSTER_ONE_KUBECONFIG) kubectl apply -f cnpg-cross-site/base/db-credentials-secret.yaml
	KUBECONFIG=$(CLUSTER_ONE_KUBECONFIG) kubectl apply -f cnpg-cross-site/cluster-one/streaming-replica-secret.yaml
	KUBECONFIG=$(CLUSTER_ONE_KUBECONFIG) kubectl apply -f cnpg-cross-site/cluster-one/primary-cluster.yaml
	KUBECONFIG=$(CLUSTER_ONE_KUBECONFIG) kubectl apply -f cnpg-cross-site/cluster-one/service-export.yaml
	@echo "Waiting for primary cluster to become ready..."
	@for i in $$(seq 1 120); do \
		READY=$$(KUBECONFIG=$(CLUSTER_ONE_KUBECONFIG) kubectl get cluster cnpg-primary -n cnpg-database -o jsonpath='{.status.readyInstances}' 2>/dev/null); \
		if [ "$$READY" -ge 1 ] 2>/dev/null; then \
			echo "Primary cluster ready ($$READY instances)"; \
			break; \
		fi; \
		echo "Waiting for primary cluster... ($$i/120)"; \
		sleep 5; \
	done
	@echo "Deploying demo database, user, and sample data..."
	KUBECONFIG=$(CLUSTER_ONE_KUBECONFIG) kubectl apply -f cnpg-cross-site/cluster-one/demo-database.yaml
	@echo "CNPG Primary deployment initiated. Run 'make cnpg-status' to check status."

cnpg-deploy-cluster-two:
	@echo "=== Deploying CNPG Operator and Base Resources on Cluster-Two ==="
	KUBECONFIG=$(CLUSTER_TWO_KUBECONFIG) kubectl apply -f cnpg-cross-site/base/namespace.yaml
	KUBECONFIG=$(CLUSTER_TWO_KUBECONFIG) kubectl apply -f cnpg-cross-site/base/subscription.yaml
	@echo "Waiting for CNPG operator CSV to be installed..."
	@for i in $$(seq 1 60); do \
		CSV=$$(KUBECONFIG=$(CLUSTER_TWO_KUBECONFIG) kubectl get csv -n openshift-operators -o name 2>/dev/null | grep cloudnative-pg); \
		if [ -n "$$CSV" ]; then \
			echo "Found CSV: $$CSV"; \
			KUBECONFIG=$(CLUSTER_TWO_KUBECONFIG) kubectl wait --for=jsonpath='{.status.phase}'=Succeeded $$CSV -n openshift-operators --timeout=300s; \
			break; \
		fi; \
		echo "Waiting for CSV... ($$i/60)"; \
		sleep 5; \
	done
	@echo "Deploying CNPG Replica cluster..."
	KUBECONFIG=$(CLUSTER_TWO_KUBECONFIG) kubectl apply -f cnpg-cross-site/base/db-credentials-secret.yaml
	KUBECONFIG=$(CLUSTER_TWO_KUBECONFIG) kubectl apply -f cnpg-cross-site/cluster-two/replica-cluster.yaml
	KUBECONFIG=$(CLUSTER_TWO_KUBECONFIG) kubectl apply -f cnpg-cross-site/cluster-two/service-export.yaml
	@echo "CNPG Replica deployment initiated. Run 'make cnpg-status' to check status."

cnpg-status:
	@echo "=== CNPG Status ==="
	@echo ""
	@echo "--- Cluster-One (Primary) ---"
	@echo "Operator CSV:"
	KUBECONFIG=$(CLUSTER_ONE_KUBECONFIG) kubectl get csv -n openshift-operators 2>/dev/null | grep -E "NAME|cloudnative-pg" || echo "No operator found"
	@echo ""
	@echo "PostgreSQL Clusters:"
	KUBECONFIG=$(CLUSTER_ONE_KUBECONFIG) kubectl get cluster -n cnpg-database 2>/dev/null || echo "No clusters found"
	@echo ""
	@echo "Pods:"
	KUBECONFIG=$(CLUSTER_ONE_KUBECONFIG) kubectl get pods -n cnpg-database 2>/dev/null || true
	@echo ""
	@echo "ServiceExport:"
	KUBECONFIG=$(CLUSTER_ONE_KUBECONFIG) kubectl get serviceexport -n cnpg-database 2>/dev/null || echo "No ServiceExports found"
	@echo ""
	@echo "--- Cluster-Two (Replica) ---"
	@echo "Operator CSV:"
	KUBECONFIG=$(CLUSTER_TWO_KUBECONFIG) kubectl get csv -n openshift-operators 2>/dev/null | grep -E "NAME|cloudnative-pg" || echo "No operator found"
	@echo ""
	@echo "PostgreSQL Clusters:"
	KUBECONFIG=$(CLUSTER_TWO_KUBECONFIG) kubectl get cluster -n cnpg-database 2>/dev/null || echo "No clusters found"
	@echo ""
	@echo "Pods:"
	KUBECONFIG=$(CLUSTER_TWO_KUBECONFIG) kubectl get pods -n cnpg-database 2>/dev/null || true
	@echo ""
	@echo "ServiceImport (from Submariner):"
	KUBECONFIG=$(CLUSTER_TWO_KUBECONFIG) kubectl get serviceimport -n cnpg-database 2>/dev/null || echo "No ServiceImports found"

cnpg-test:
	@echo "=== Testing CNPG Cross-Cluster Replication ==="
	@echo "Deploying test pod on Cluster-Two..."
	KUBECONFIG=$(CLUSTER_TWO_KUBECONFIG) kubectl apply -f cnpg-cross-site/test-connectivity.yaml
	@echo ""
	@echo "To run the connectivity test, execute:"
	@echo "  KUBECONFIG=$(CLUSTER_TWO_KUBECONFIG) kubectl exec -it cnpg-connectivity-test -n cnpg-database -- bash"
	@echo "  # Then run: sh /test.sh"
	@echo ""
	@echo "Or run directly:"
	@echo "  KUBECONFIG=$(CLUSTER_TWO_KUBECONFIG) kubectl exec cnpg-connectivity-test -n cnpg-database -- psql -h cnpg-primary-rw.cnpg-database.svc.clusterset.local -U postgres -d appdb -c 'SELECT version();'"

cnpg-delete:
	@echo "=== Deleting CNPG Resources ==="
	@echo "Deleting cluster-two resources..."
	KUBECONFIG=$(CLUSTER_TWO_KUBECONFIG) kubectl delete -f cnpg-cross-site/cluster-two/replica-cluster.yaml --ignore-not-found || true
	KUBECONFIG=$(CLUSTER_TWO_KUBECONFIG) kubectl delete -f cnpg-cross-site/cluster-two/service-export.yaml --ignore-not-found || true
	KUBECONFIG=$(CLUSTER_TWO_KUBECONFIG) kubectl delete -f cnpg-cross-site/base/db-credentials-secret.yaml --ignore-not-found || true
	KUBECONFIG=$(CLUSTER_TWO_KUBECONFIG) kubectl delete -f cnpg-cross-site/base/namespace.yaml --ignore-not-found || true
	@echo "Deleting cluster-one resources..."
	KUBECONFIG=$(CLUSTER_ONE_KUBECONFIG) kubectl delete -f cnpg-cross-site/cluster-one/demo-database.yaml --ignore-not-found || true
	KUBECONFIG=$(CLUSTER_ONE_KUBECONFIG) kubectl delete -f cnpg-cross-site/cluster-one/primary-cluster.yaml --ignore-not-found || true
	KUBECONFIG=$(CLUSTER_ONE_KUBECONFIG) kubectl delete -f cnpg-cross-site/cluster-one/service-export.yaml --ignore-not-found || true
	KUBECONFIG=$(CLUSTER_ONE_KUBECONFIG) kubectl delete -f cnpg-cross-site/cluster-one/streaming-replica-secret.yaml --ignore-not-found || true
	KUBECONFIG=$(CLUSTER_ONE_KUBECONFIG) kubectl delete -f cnpg-cross-site/base/db-credentials-secret.yaml --ignore-not-found || true
	KUBECONFIG=$(CLUSTER_ONE_KUBECONFIG) kubectl delete -f cnpg-cross-site/base/namespace.yaml --ignore-not-found || true
	@echo "Note: Operator subscription left in place. Delete manually if needed."

# ========== Demo Database Operations ==========

show_entries:
	@echo "=== Demo Table Entries ==="
	@echo ""
	@echo "--- Cluster-One (Primary) ---"
	@PRIMARY_POD=$$(KUBECONFIG=$(CLUSTER_ONE_KUBECONFIG) kubectl get pods -n cnpg-database -l cnpg.io/cluster=cnpg-primary,role=primary -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -n "$$PRIMARY_POD" ]; then \
		KUBECONFIG=$(CLUSTER_ONE_KUBECONFIG) kubectl exec $$PRIMARY_POD -n cnpg-database -- bash -c "PGPASSWORD=apppassword psql -h localhost -U app -d appdb -c 'SELECT * FROM items ORDER BY id;'"; \
	else \
		echo "Primary pod not found"; \
	fi
	@echo ""
	@echo "--- Cluster-Two (Replica) ---"
	@REPLICA_POD=$$(KUBECONFIG=$(CLUSTER_TWO_KUBECONFIG) kubectl get pods -n cnpg-database -l cnpg.io/cluster=cnpg-replica -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -n "$$REPLICA_POD" ]; then \
		KUBECONFIG=$(CLUSTER_TWO_KUBECONFIG) kubectl exec $$REPLICA_POD -n cnpg-database -- bash -c "PGPASSWORD=apppassword psql -h localhost -U app -d appdb -c 'SELECT * FROM items ORDER BY id;'"; \
	else \
		echo "Replica pod not found"; \
	fi

add_entry:
	@echo "=== Adding Random Entry to Demo Table ==="
	@PRIMARY_POD=$$(KUBECONFIG=$(CLUSTER_ONE_KUBECONFIG) kubectl get pods -n cnpg-database -l cnpg.io/cluster=cnpg-primary,role=primary -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$PRIMARY_POD" ]; then \
		echo "ERROR: Primary pod not found!"; \
		exit 1; \
	fi; \
	echo "Found primary pod: $$PRIMARY_POD"; \
	RANDOM_NAME="Item-$$(date +%s)"; \
	RANDOM_QTY=$$(( (RANDOM % 100) + 1 )); \
	RANDOM_PRICE=$$(printf "%.2f" $$(echo "scale=2; ($$RANDOM % 10000) / 100" | bc)); \
	echo "Inserting: name=$$RANDOM_NAME, quantity=$$RANDOM_QTY, price=$$RANDOM_PRICE"; \
	KUBECONFIG=$(CLUSTER_ONE_KUBECONFIG) kubectl exec $$PRIMARY_POD -n cnpg-database -- bash -c "PGPASSWORD=apppassword psql -h localhost -U app -d appdb -c \"INSERT INTO items (name, description, quantity, price) VALUES ('$$RANDOM_NAME', 'Auto-generated entry', $$RANDOM_QTY, $$RANDOM_PRICE) RETURNING *;\""
