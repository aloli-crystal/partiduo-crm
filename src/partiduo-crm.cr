# SPDX-License-Identifier: AGPL-3.0-or-later

# Point d'entrée du shard `partiduo-crm` : le métier de l'extension CRM
# (manifeste, modèles, abonnements, contrat `Crm::Api`), sans interface.
# L'interface Bulma est dans `ui/bulma/`, requise à part par la
# distribution : `require "partiduo-crm/ui/bulma"`.
#
# La distribution ajoute ensuite `Crm::INSTALLED_APPS` à ses applications
# Marten, et `require "partiduo-crm/cli"` à sa ligne de commande
# (migrations).
require "partiduo"

require "./crm/app"
