# SPDX-License-Identifier: AGPL-3.0-or-later

# Manifeste de l'extension CRM (ADR-003 D2, ADR-009).
#
# * Dépendance : `INVOICING` (D1) — sans devis, le pipeline n'aboutit à rien.
# * Permissions (D7) : `crm.read` (consulter), `crm.write` (saisir
#   organisations, contacts, opportunités, activités ; importer),
#   `crm.admin` (étapes, motifs de perte, origines, effacement RGPD). Créer
#   un devis exige en plus `invoicing.invoice.write` ; faire devenir client
#   une organisation, `cards.card.write` (D-CRM-004).
# * Menu (D6) : rubrique « Relation client » de premier niveau, entre la
#   Facturation et le Suivi, et paramètres sous « Paramètres ».
# * Abonnements : `card.saved` (une fiche client créée hors du CRM y
#   apparaît), `quote.decided` (devis accepté → « Gagnée », refusé →
#   activité « relancer »), `invoice.issued` (facture rattachée à
#   l'opportunité de son devis).
Partiduo::Modules.register do
  code "CRM"
  name "crm.module.name"
  version "0.1.0"
  requires_core "~> 0.1"
  depends_on "INVOICING"

  permission "crm.read"
  permission "crm.write"
  permission "crm.admin"

  menu "CRM", order: 22, permission: "crm.read"
  menu "CRM_DASHBOARD", parent: "CRM", order: 10, route: "crm:dashboard", permission: "crm.read"
  menu "CRM_PIPELINE", parent: "CRM", order: 20, route: "crm:pipeline", permission: "crm.read"
  menu "CRM_OPPORTUNITIES", parent: "CRM", order: 30, route: "crm:opportunities", permission: "crm.read"
  menu "CRM_ACTIVITIES", parent: "CRM", order: 40, route: "crm:activities", permission: "crm.read"
  menu "CRM_ORGANIZATIONS", parent: "CRM", order: 50, route: "crm:organizations", permission: "crm.read"
  menu "CRM_CONTACTS", parent: "CRM", order: 60, route: "crm:contacts", permission: "crm.read"
  menu "CRM_IMPORT", parent: "CRM", order: 70, route: "crm:import", permission: "crm.write"
  menu "CRM_SETTINGS", parent: "SETTINGS", order: 96, route: "crm:settings", permission: "crm.admin"

  ui "bulma", path: "ui/bulma"

  on("card.saved") { |event| Crm::Subscriptions.card_saved(event) }
  on("quote.decided") { |event| Crm::Subscriptions.quote_decided(event) }
  on("invoice.issued") { |event| Crm::Subscriptions.invoice_issued(event) }
end
