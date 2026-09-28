# SPDX-License-Identifier: AGPL-3.0-or-later

# Interface Bulma de l'extension CRM (ADR-005 D4, ADR-009) : tableau de bord
# commercial, pipeline en colonnes (déplacement au clavier et à la souris,
# HTMX), opportunités, organisations, contacts, « Mes activités », import
# CSV, paramétrage. Montée par `partiduo-ui-bulma` sous `/ext/CRM/`
# (ADR-003 D3). La distribution la requiert après l'interface :
#
# ```
# require "partiduo-ui-bulma/partiduo_ui"
# require "partiduo-crm"
# require "partiduo-crm/ui/bulma"
# ```
#
# puis ajoute `Crm::Ui::INSTALLED_APPS` à ses applications Marten.
#
# Ce dossier ne parle au métier que par `Crm::Api` et `Partiduo::Api`
# (vérifié par `spec/architecture/conventions_spec.cr`) ; le contrôle d'accès
# est fait par l'interface, avant le handler, à partir du montage, puis par
# le contrat.
require "../../src/partiduo-crm"

require "./presenters"
require "./handlers/base"
require "./handlers/**"
require "./dashboard_tile"

module Crm
  module Ui
    # Application Marten de l'interface Bulma de l'extension : gabarits
    # (`templates/crm/`), fichiers statiques (`assets/crm/`) et libellés
    # d'écran (`locales/`, clés `crm_ui.*`).
    class App < Marten::App
      label "crm_ui"
    end

    INSTALLED_APPS = [Crm::Ui::App] of Marten::Apps::Config.class

    # Routes servies sous `/ext/CRM/`, nommées `crm:<nom>` : celles que
    # citent les menus du manifeste (`crm:dashboard`, `crm:pipeline`…).
    ROUTES = Marten::Routing::Map.draw do
      path "/", Crm::Ui::IndexHandler, name: "index"
      path "/dashboard", Crm::Ui::DashboardHandler, name: "dashboard"
      path "/pipeline", Crm::Ui::PipelineHandler, name: "pipeline"
      path "/opportunities", Crm::Ui::OpportunitiesHandler, name: "opportunities"
      path "/opportunities/new", Crm::Ui::OpportunityNewHandler, name: "opportunity_new"
      path "/opportunities/<id:int>", Crm::Ui::OpportunityHandler, name: "opportunity"
      path "/opportunities/<id:int>/edit", Crm::Ui::OpportunityEditHandler, name: "opportunity_edit"
      path "/opportunities/<id:int>/move", Crm::Ui::OpportunityMoveHandler, name: "opportunity_move"
      path "/opportunities/<id:int>/quote", Crm::Ui::OpportunityQuoteHandler, name: "opportunity_quote"
      path "/organizations", Crm::Ui::OrganizationsHandler, name: "organizations"
      path "/organizations/new", Crm::Ui::OrganizationNewHandler, name: "organization_new"
      path "/organizations/<id:int>", Crm::Ui::OrganizationHandler, name: "organization"
      path "/organizations/<id:int>/edit", Crm::Ui::OrganizationEditHandler, name: "organization_edit"
      path "/organizations/<id:int>/customer", Crm::Ui::OrganizationCustomerHandler, name: "organization_customer"
      path "/organizations/<id:int>/delete", Crm::Ui::OrganizationDeleteHandler, name: "organization_delete"
      path "/contacts", Crm::Ui::ContactsHandler, name: "contacts"
      path "/contacts/export", Crm::Ui::ContactsExportHandler, name: "contacts_export"
      path "/contacts/new", Crm::Ui::ContactNewHandler, name: "contact_new"
      path "/contacts/<id:int>", Crm::Ui::ContactHandler, name: "contact"
      path "/contacts/<id:int>/edit", Crm::Ui::ContactEditHandler, name: "contact_edit"
      path "/contacts/<id:int>/opposition", Crm::Ui::ContactOppositionHandler, name: "contact_opposition"
      path "/contacts/<id:int>/withdraw", Crm::Ui::ContactWithdrawHandler, name: "contact_withdraw"
      path "/contacts/<id:int>/erase", Crm::Ui::ContactEraseHandler, name: "contact_erase"
      path "/activities", Crm::Ui::ActivitiesHandler, name: "activities"
      path "/activities/new", Crm::Ui::ActivityNewHandler, name: "activity_new"
      path "/activities/<id:int>/edit", Crm::Ui::ActivityEditHandler, name: "activity_edit"
      path "/activities/<id:int>/done", Crm::Ui::ActivityDoneHandler, name: "activity_done"
      path "/activities/<id:int>/delete", Crm::Ui::ActivityDeleteHandler, name: "activity_delete"
      path "/import", Crm::Ui::ImportHandler, name: "import"
      path "/settings", Crm::Ui::SettingsHandler, name: "settings"
      path "/settings/<kind:str>", Crm::Ui::SettingsCreateHandler, name: "settings_create"
      path "/settings/<kind:str>/<id:int>", Crm::Ui::SettingsUpdateHandler, name: "settings_update"
    end

    # Routes qui modifient : `crm.write` ; paramétrage et effacement RGPD :
    # `crm.admin` ; les autres : `crm.read`. Le contrat vérifie encore les
    # permissions du cœur (Facturation, fiches).
    WRITE_ROUTES = %w[opportunity_new opportunity_edit opportunity_move opportunity_quote organization_new
      organization_edit organization_customer contact_new contact_edit contact_opposition activity_new activity_edit
      activity_done activity_delete import]
    ADMIN_ROUTES = %w[organization_delete contact_withdraw contact_erase settings settings_create settings_update]
  end
end

PartiduoUi::Extensions.mount Crm::CODE, Crm::Ui::ROUTES, permission: Crm::Api::READ,
  permissions: Crm::Ui::WRITE_ROUTES.to_h { |route| {route, Crm::Api::WRITE} }
    .merge(Crm::Ui::ADMIN_ROUTES.to_h { |route| {route, Crm::Api::ADMIN} })

# Compteur du menu « Mes activités » et ligne de « À traiter » du tableau de
# bord du dossier : activités de l'utilisateur en retard ou du jour.
PartiduoUi::Extensions.counter("CRM_ACTIVITIES", route: "crm:activities", todo: "crm_ui.todo", tone: "warn") do |actor|
  Crm::Api.due_count(actor)
end
