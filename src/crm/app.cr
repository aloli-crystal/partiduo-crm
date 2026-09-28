# SPDX-License-Identifier: AGPL-3.0-or-later

require "csv"

require "./manifest"
require "./models/**"
require "./services/**"
require "./api/**"

# Extension CRM de Partiduo (ADR-009) : le suivi commercial *avant* le
# devis — organisations et contacts, opportunités dans un pipeline par
# étapes, activités à échéance, passage au devis de la Facturation, tableau
# de bord commercial. Même plan qu'une application du cœur (DECISIONS C1 du
# cœur) : `manifest.cr`, `models/`, `migrations/`, `services/` (interne),
# `api/` (contrat public `Crm::Api`), `locales/`.
module Crm
  VERSION = "0.1.0"

  # Code du registre (ADR-003 D2) : `crm` dans `PARTIDUO_MODULES`.
  CODE = "CRM"

  # Application Marten du métier : modèles (tables `crm_*`), migrations et
  # libellés.
  class App < Marten::App
    label "crm"
  end

  # Applications Marten du métier, à ajouter à `installed_apps` de la
  # distribution après `Partiduo::INSTALLED_APPS`.
  INSTALLED_APPS = [Crm::App] of Marten::Apps::Config.class
end
