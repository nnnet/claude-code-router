.PHONY: bdd bdd-provider-free-model-scripts bdd-free-model-refresh smoke-provider-free-models-live acceptance-redundancy spec-coverage openspec-validate

bdd: bdd-provider-free-model-scripts bdd-free-model-refresh

bdd-provider-free-model-scripts:
	@./bdd/steps/provider-free-model-scripts.sh

bdd-free-model-refresh:
	@./bdd/steps/free-model-refresh.sh

smoke-provider-free-models-live:
	@./bdd/steps/provider-free-models-live-smoke.sh

acceptance-redundancy:
	@./bdd/steps/check-redundancy.sh

spec-coverage:
	@agent-ops spec-coverage .

openspec-validate:
	@openspec validate --all --strict
