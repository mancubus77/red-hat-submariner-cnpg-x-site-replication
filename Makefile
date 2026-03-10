.PHONY: all create destroy create-cluster1 create-cluster2 destroy-cluster1 destroy-cluster2 \
	submariner-deploy submariner-status \
	cnpg-deploy-cluster1 cnpg-deploy-cluster2 cnpg-deploy cnpg-status cnpg-test cnpg-delete \
	show_entries add_entry

INSTALLER := /Users/skozlov/.local/bin/openshift-install
ENV_FILE := .env
HUB_KUBECONFIG := cluster1/auth/kubeconfig

all: create

create: create-cluster1 create-cluster2

destroy: destroy-cluster1 destroy-cluster2

create-cluster1:
	@echo "=== Creating cluster1 (us-east-2) ==="
	@cd cluster1 && set -a && source ../$(ENV_FILE) && set +a && \
		$(INSTALLER) create cluster --log-level=info 2>&1 | tee install.log

create-cluster2:
	@echo "=== Creating cluster2 (us-west-2) ==="
	@cd cluster2 && set -a && source ../$(ENV_FILE) && set +a && \
		$(INSTALLER) create cluster --log-level=info 2>&1 | tee install.log

destroy-cluster1:
	@echo "=== Destroying cluster1 ==="
	@cd cluster1 && set -a && source ../$(ENV_FILE) && set +a && \
		$(INSTALLER) destroy cluster --log-level=info 2>&1 | tee destroy.log

destroy-cluster2:
	@echo "=== Destroying cluster2 ==="
	@cd cluster2 && set -a && source ../$(ENV_FILE) && set +a && \
		$(INSTALLER) destroy cluster --log-level=info 2>&1 | tee destroy.log

# ========== Submariner Deployment ==========

submariner-deploy:
	@echo "=== Deploying Submariner with Globalnet mode ==="
	@if [ -z "$$AWS_ACCESS_KEY_ID" ] || [ -z "$$AWS_SECRET_ACCESS_KEY" ]; then \
		echo "ERROR: Run 'source .env' first"; exit 1; fi
	KUBECONFIG=$(HUB_KUBECONFIG) envsubst < manifests/secrets/local-cluster-aws-creds.yaml | kubectl apply -f -
	KUBECONFIG=$(HUB_KUBECONFIG) envsubst < manifests/secrets/cluster2-aws-creds.yaml | kubectl apply -f -
	KUBECONFIG=$(HUB_KUBECONFIG) kubectl apply -k manifests/

submariner-status:
	@echo "=== Submariner Status ==="
	KUBECONFIG=$(HUB_KUBECONFIG) kubectl get managedclusteraddon -A | grep submariner || true
	@echo ""
	KUBECONFIG=cluster1/auth/kubeconfig kubectl get gateway -n submariner-operator 2>/dev/null || true
	KUBECONFIG=cluster2/auth/kubeconfig kubectl get gateway -n submariner-operator 2>/dev/null || true

# ========== CNPG Cross-Site Deployment ==========

CLUSTER1_KUBECONFIG := cluster1/auth/kubeconfig
CLUSTER2_KUBECONFIG := cluster2/auth/kubeconfig

cnpg-deploy: cnpg-deploy-cluster1 cnpg-deploy-cluster2

cnpg-deploy-cluster1:
	@echo "=== Deploying CNPG Operator and Base Resources on Cluster1 ==="
	KUBECONFIG=$(CLUSTER1_KUBECONFIG) kubectl apply -f cnpg-cross-site/base/namespace.yaml
	KUBECONFIG=$(CLUSTER1_KUBECONFIG) kubectl apply -f cnpg-cross-site/base/subscription.yaml
	@echo "Waiting for CNPG operator CSV to be installed..."
	@for i in $$(seq 1 60); do \
		CSV=$$(KUBECONFIG=$(CLUSTER1_KUBECONFIG) kubectl get csv -n openshift-operators -o name 2>/dev/null | grep cloudnative-pg); \
		if [ -n "$$CSV" ]; then \
			echo "Found CSV: $$CSV"; \
			KUBECONFIG=$(CLUSTER1_KUBECONFIG) kubectl wait --for=jsonpath='{.status.phase}'=Succeeded $$CSV -n openshift-operators --timeout=300s; \
			break; \
		fi; \
		echo "Waiting for CSV... ($$i/60)"; \
		sleep 5; \
	done
	@echo "Deploying CNPG Primary cluster..."
	KUBECONFIG=$(CLUSTER1_KUBECONFIG) kubectl apply -f cnpg-cross-site/base/db-credentials-secret.yaml
	KUBECONFIG=$(CLUSTER1_KUBECONFIG) kubectl apply -f cnpg-cross-site/cluster1/streaming-replica-secret.yaml
	KUBECONFIG=$(CLUSTER1_KUBECONFIG) kubectl apply -f cnpg-cross-site/cluster1/primary-cluster.yaml
	KUBECONFIG=$(CLUSTER1_KUBECONFIG) kubectl apply -f cnpg-cross-site/cluster1/service-export.yaml
	@echo "CNPG Primary deployment initiated. Run 'make cnpg-status' to check status."

cnpg-deploy-cluster2:
	@echo "=== Deploying CNPG Operator and Base Resources on Cluster2 ==="
	KUBECONFIG=$(CLUSTER2_KUBECONFIG) kubectl apply -f cnpg-cross-site/base/namespace.yaml
	KUBECONFIG=$(CLUSTER2_KUBECONFIG) kubectl apply -f cnpg-cross-site/base/subscription.yaml
	@echo "Waiting for CNPG operator CSV to be installed..."
	@for i in $$(seq 1 60); do \
		CSV=$$(KUBECONFIG=$(CLUSTER2_KUBECONFIG) kubectl get csv -n openshift-operators -o name 2>/dev/null | grep cloudnative-pg); \
		if [ -n "$$CSV" ]; then \
			echo "Found CSV: $$CSV"; \
			KUBECONFIG=$(CLUSTER2_KUBECONFIG) kubectl wait --for=jsonpath='{.status.phase}'=Succeeded $$CSV -n openshift-operators --timeout=300s; \
			break; \
		fi; \
		echo "Waiting for CSV... ($$i/60)"; \
		sleep 5; \
	done
	@echo "Deploying CNPG Replica cluster..."
	KUBECONFIG=$(CLUSTER2_KUBECONFIG) kubectl apply -f cnpg-cross-site/base/db-credentials-secret.yaml
	KUBECONFIG=$(CLUSTER2_KUBECONFIG) kubectl apply -f cnpg-cross-site/cluster2/replica-cluster.yaml
	KUBECONFIG=$(CLUSTER2_KUBECONFIG) kubectl apply -f cnpg-cross-site/cluster2/service-export.yaml
	@echo "CNPG Replica deployment initiated. Run 'make cnpg-status' to check status."

cnpg-status:
	@echo "=== CNPG Status ==="
	@echo ""
	@echo "--- Cluster1 (Primary) ---"
	@echo "Operator CSV:"
	KUBECONFIG=$(CLUSTER1_KUBECONFIG) kubectl get csv -n openshift-operators 2>/dev/null | grep -E "NAME|cloudnative-pg" || echo "No operator found"
	@echo ""
	@echo "PostgreSQL Clusters:"
	KUBECONFIG=$(CLUSTER1_KUBECONFIG) kubectl get cluster -n cnpg-database 2>/dev/null || echo "No clusters found"
	@echo ""
	@echo "Pods:"
	KUBECONFIG=$(CLUSTER1_KUBECONFIG) kubectl get pods -n cnpg-database 2>/dev/null || true
	@echo ""
	@echo "ServiceExport:"
	KUBECONFIG=$(CLUSTER1_KUBECONFIG) kubectl get serviceexport -n cnpg-database 2>/dev/null || echo "No ServiceExports found"
	@echo ""
	@echo "--- Cluster2 (Replica) ---"
	@echo "Operator CSV:"
	KUBECONFIG=$(CLUSTER2_KUBECONFIG) kubectl get csv -n openshift-operators 2>/dev/null | grep -E "NAME|cloudnative-pg" || echo "No operator found"
	@echo ""
	@echo "PostgreSQL Clusters:"
	KUBECONFIG=$(CLUSTER2_KUBECONFIG) kubectl get cluster -n cnpg-database 2>/dev/null || echo "No clusters found"
	@echo ""
	@echo "Pods:"
	KUBECONFIG=$(CLUSTER2_KUBECONFIG) kubectl get pods -n cnpg-database 2>/dev/null || true
	@echo ""
	@echo "ServiceImport (from Submariner):"
	KUBECONFIG=$(CLUSTER2_KUBECONFIG) kubectl get serviceimport -n cnpg-database 2>/dev/null || echo "No ServiceImports found"

cnpg-test:
	@echo "=== Testing CNPG Cross-Cluster Replication ==="
	@echo "Deploying test pod on Cluster2..."
	KUBECONFIG=$(CLUSTER2_KUBECONFIG) kubectl apply -f cnpg-cross-site/test-connectivity.yaml
	@echo ""
	@echo "To run the connectivity test, execute:"
	@echo "  KUBECONFIG=$(CLUSTER2_KUBECONFIG) kubectl exec -it cnpg-connectivity-test -n cnpg-database -- bash"
	@echo "  # Then run: sh /test.sh"
	@echo ""
	@echo "Or run directly:"
	@echo "  KUBECONFIG=$(CLUSTER2_KUBECONFIG) kubectl exec cnpg-connectivity-test -n cnpg-database -- psql -h cnpg-primary-rw.cnpg-database.svc.clusterset.local -U postgres -d appdb -c 'SELECT version();'"

cnpg-delete:
	@echo "=== Deleting CNPG Resources ==="
	@echo "Deleting cluster2 resources..."
	KUBECONFIG=$(CLUSTER2_KUBECONFIG) kubectl delete -f cnpg-cross-site/cluster2/replica-cluster.yaml --ignore-not-found || true
	KUBECONFIG=$(CLUSTER2_KUBECONFIG) kubectl delete -f cnpg-cross-site/cluster2/service-export.yaml --ignore-not-found || true
	KUBECONFIG=$(CLUSTER2_KUBECONFIG) kubectl delete -f cnpg-cross-site/base/db-credentials-secret.yaml --ignore-not-found || true
	KUBECONFIG=$(CLUSTER2_KUBECONFIG) kubectl delete -f cnpg-cross-site/base/namespace.yaml --ignore-not-found || true
	@echo "Deleting cluster1 resources..."
	KUBECONFIG=$(CLUSTER1_KUBECONFIG) kubectl delete -f cnpg-cross-site/cluster1/primary-cluster.yaml --ignore-not-found || true
	KUBECONFIG=$(CLUSTER1_KUBECONFIG) kubectl delete -f cnpg-cross-site/cluster1/service-export.yaml --ignore-not-found || true
	KUBECONFIG=$(CLUSTER1_KUBECONFIG) kubectl delete -f cnpg-cross-site/cluster1/streaming-replica-secret.yaml --ignore-not-found || true
	KUBECONFIG=$(CLUSTER1_KUBECONFIG) kubectl delete -f cnpg-cross-site/base/db-credentials-secret.yaml --ignore-not-found || true
	KUBECONFIG=$(CLUSTER1_KUBECONFIG) kubectl delete -f cnpg-cross-site/base/namespace.yaml --ignore-not-found || true
	@echo "Note: Operator subscription left in place. Delete manually if needed."

# ========== Demo Database Operations ==========

show_entries:
	@echo "=== Demo Table Entries ==="
	@echo ""
	@echo "--- Cluster1 (Primary) ---"
	@PRIMARY_POD=$$(KUBECONFIG=$(CLUSTER1_KUBECONFIG) kubectl get pods -n cnpg-database -l cnpg.io/cluster=cnpg-primary,role=primary -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -n "$$PRIMARY_POD" ]; then \
		KUBECONFIG=$(CLUSTER1_KUBECONFIG) kubectl exec $$PRIMARY_POD -n cnpg-database -- bash -c "PGPASSWORD=demo psql -h localhost -U demo -d demo -c 'SELECT * FROM items ORDER BY id;'"; \
	else \
		echo "Primary pod not found"; \
	fi
	@echo ""
	@echo "--- Cluster2 (Replica) ---"
	@REPLICA_POD=$$(KUBECONFIG=$(CLUSTER2_KUBECONFIG) kubectl get pods -n cnpg-database -l cnpg.io/cluster=cnpg-replica -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -n "$$REPLICA_POD" ]; then \
		KUBECONFIG=$(CLUSTER2_KUBECONFIG) kubectl exec $$REPLICA_POD -n cnpg-database -- bash -c "PGPASSWORD=demo psql -h localhost -U demo -d demo -c 'SELECT * FROM items ORDER BY id;'"; \
	else \
		echo "Replica pod not found"; \
	fi

add_entry:
	@echo "=== Adding Random Entry to Demo Table ==="
	@PRIMARY_POD=$$(KUBECONFIG=$(CLUSTER1_KUBECONFIG) kubectl get pods -n cnpg-database -l cnpg.io/cluster=cnpg-primary,role=primary -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$PRIMARY_POD" ]; then \
		echo "ERROR: Primary pod not found!"; \
		exit 1; \
	fi; \
	echo "Found primary pod: $$PRIMARY_POD"; \
	RANDOM_NAME="Item-$$(date +%s)"; \
	RANDOM_QTY=$$(( (RANDOM % 100) + 1 )); \
	RANDOM_PRICE=$$(printf "%.2f" $$(echo "scale=2; ($$RANDOM % 10000) / 100" | bc)); \
	echo "Inserting: name=$$RANDOM_NAME, quantity=$$RANDOM_QTY, price=$$RANDOM_PRICE"; \
	KUBECONFIG=$(CLUSTER1_KUBECONFIG) kubectl exec $$PRIMARY_POD -n cnpg-database -- bash -c "PGPASSWORD=demo psql -h localhost -U demo -d demo -c \"INSERT INTO items (name, description, quantity, price) VALUES ('$$RANDOM_NAME', 'Auto-generated entry', $$RANDOM_QTY, $$RANDOM_PRICE) RETURNING *;\""
