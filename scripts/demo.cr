# SPDX-License-Identifier: AGPL-3.0-or-later

# Instance de démonstration de la relation client, composée comme une
# distribution (cœur, interface Bulma, extension CRM), servie par Marten
# dans ce processus. Au premier lancement sur une base vide : migrations,
# dossier « Atelier Brunet SARL », exercice de l'année, deux utilisateurs,
# extension activée, données de démonstration (prospects et clients,
# contacts dont un opposé à la prospection, opportunités à toutes les
# étapes, un devis, activités en retard, du jour et à venir). Les
# lancements suivants reprennent la base telle quelle.
#
# ```
# createdb -h /tmp partiduo_crm_demo
# DATABASE_URL='postgres:///partiduo_crm_demo?host=/tmp' PORT=8010 \
#   crystal run scripts/demo.cr
# ```
#
# Puis http://127.0.0.1:8010/ext/CRM/pipeline, identifiants ci-dessous
# (`DEMO_EMAIL`, `DEMO_PASSWORD`). Arrêt : Ctrl+C.
ENV["MARTEN_ENV"] ||= "development"

require "partiduo-ui-bulma/partiduo_ui"
require "../src/partiduo-crm"
require "../ui/bulma/bulma"
require "../config/settings/base"
require "../config/settings/**"
require "partiduo/cli"
require "../src/partiduo-crm/cli"

module CrmDemo
  alias Api = Crm::Api
  alias Inv = Partiduo::Api::Invoicing
  alias Cards = Partiduo::Api::Cards

  # Identifiants de démonstration (base locale seulement) : 14 caractères
  # et plus, majuscule, minuscule, chiffre (politique du cœur).
  DEMO_EMAIL    = "demo@crm.partiduo.test"
  DEMO_PASSWORD = "Tournesol-Vitrine-2026"
  # Second utilisateur, responsable d'une partie des opportunités.
  SECOND_EMAIL = "bruno@crm.partiduo.test"

  def self.system : Partiduo::Api::Actor
    Partiduo::Api::Actor.system
  end

  def self.today : Time
    Partiduo::Api::Core.today
  end

  def self.d(text : String) : BigDecimal
    BigDecimal.new(text)
  end

  def self.run : Nil
    connection = Marten::DB::Connection.default
    name = Marten.settings.databases.first.name.to_s
    puts "== Base #{name} : migrations"
    Marten::DB::Management::Migrations::Runner.new(connection).execute
    Partiduo::Modules::State.reset_table_cache
    provision unless Partiduo::Api::Auth.user_by_email(system, DEMO_EMAIL)
    Partiduo::Api::Modules.activate(system, Crm::CODE)
    Crm::Defaults.ensure!
    seed if Api.organizations(system).empty?
    puts "== Prêt : http://#{Marten.settings.host}:#{Marten.settings.port}/ext/CRM/pipeline"
    puts "   Connexion : #{DEMO_EMAIL} / #{DEMO_PASSWORD}"
  end

  # Dossier, exercice, utilisateurs (profil administrateur).
  private def self.provision : Nil
    puts "== Dossier de démonstration"
    settings = Partiduo::Api::Core::SettingsInput.new(company_name: "Atelier Brunet SARL", tax_regime: "fr", country_code: "FR",
      siren: "732 829 320", vat_number: "FR 44 732829320", domain: "demo.partiduo.localhost")
    Partiduo::Api::Core.provision(system, Partiduo::Api::Core::ProvisionInput.new(settings: settings, modules: [] of String)).value!
    year = today.year
    if Partiduo::Api::Core.fiscal_years(system).none?(&.year.==(year))
      Partiduo::Api::Core.create_fiscal_year(system, Partiduo::Api::Core::FiscalYearInput.new(year: year, start_year: year)).value!
    end
    profile = Partiduo::Api::Auth.ensure_default_profiles(system).find! { |item| item.code == "ADMIN" }.id
    {DEMO_EMAIL => {"Claire", "Brunet"}, SECOND_EMAIL => {"Bruno", "Lefèvre"}}.each do |email, (first, last)|
      input = Partiduo::Api::Auth::UserInput.new(email: email, first_name: first, last_name: last, role: "member",
        profile_id: profile, password: DEMO_PASSWORD)
      Partiduo::Api::Auth.create_user(system, input).value!
    end
  end

  private def self.user(email : String) : Partiduo::Api::Actor
    id = Partiduo::Api::Auth.user_by_email(system, email).try(&.id) || raise "utilisateur #{email} absent"
    Partiduo::Api::Actor.user(id, [Api::READ, Api::WRITE, Api::ADMIN, "cards.card.read", "cards.card.write", Inv::READ, Inv::WRITE])
  end

  private def self.stage(code : String) : Int64
    Api.stages(system).find! { |item| item.code == code }.id
  end

  private def self.source(code : String) : Int64
    Api.sources(system).find! { |item| item.code == code }.id
  end

  # Données de démonstration, écrites par le contrat de l'extension.
  private def self.seed : Nil
    puts "== Données de démonstration"
    claire = user(DEMO_EMAIL)
    bruno = user(SECOND_EMAIL)
    bruno_id = bruno.user_id

    organizations = {
      "leroux"  => {"Menuiserie Leroux", "443061841", "Tours", "fair"},
      "petit"   => {"Boulangerie Petit", "", "Amboise", "website"},
      "morel"   => {"Garage Morel", "552100554", "Blois", "referral"},
      "mairie"  => {"Mairie de Vouvray", "213702761", "Vouvray", "prospecting"},
      "durand"  => {"Cabinet Durand", "", "Tours", "network"},
      "martin"  => {"Jeanne Martin", "", "Joué-lès-Tours", "website"},
      "horizon" => {"Horizon Paysage", "", "Chinon", "fair"},
    }.to_h do |key, (name, siren, city, origin)|
      nature = key == "mairie" ? "public" : (key == "martin" ? "individual" : "business")
      input = Api::OrganizationInput.new(name: name, nature: nature, siren: siren, city: city, country_code: "FR",
        source_id: source(origin), owner_id: key.in?("petit", "durand", "horizon") ? bruno_id : claire.user_id)
      {key, Api.create_organization(claire, input).value!.id}
    end
    Api.become_customer(claire, organizations["morel"], Api::CustomerInput.new(nature: "business")).value!

    contacts = {
      "paul"  => {"leroux", "mr", "Paul", "Leroux", "Gérant", "paul@leroux.test"},
      "anne"  => {"leroux", "ms", "Anne", "Leroux", "Comptable", "anne@leroux.test"},
      "luc"   => {"petit", "mr", "Luc", "Petit", "Artisan boulanger", "luc@petit.test"},
      "sarah" => {"morel", "ms", "Sarah", "Morel", "Directrice", "sarah@morel.test"},
      "remi"  => {"mairie", "mr", "Rémi", "Caron", "Secrétaire général", "r.caron@vouvray.test"},
      "ines"  => {"durand", "ms", "Inès", "Durand", "Associée", "ines@durand.test"},
    }.to_h do |key, (organization, civility, first, last, job, email)|
      input = Api::ContactInput.new(last_name: last, first_name: first, organization_id: organizations[organization],
        civility: civility, job_title: job, email: email, legal_basis: "legitimate_interest", source_id: source("fair"))
      {key, Api.create_contact(claire, input).value!.id}
    end
    opposed = Api.create_contact(claire, Api::ContactInput.new(last_name: "Garnier", first_name: "Hugo",
      organization_id: organizations["horizon"], email: "hugo@horizon.test", legal_basis: "consent")).value!
    Api.record_opposition(claire, opposed.id, "Demande reçue par courriel").value!

    opportunity = ->(title : String, organization : String, contact : String?, amount : String, code : String, owner : Partiduo::Api::Actor, close_in : Int32) do
      stage_code = code.in?("won", "lost") ? "negotiation" : code
      input = Api::OpportunityInput.new(title: title, organization_id: organizations[organization],
        contact_id: contact.try { |key| contacts[key] }, amount: d(amount), expected_close_on: today + close_in.days,
        owner_id: owner.user_id, stage_id: stage(stage_code), source_id: source("fair"))
      Api.create_opportunity(owner, input).value!.id
    end
    opportunity.call("Découverte : agencement du fournil", "petit", "luc", "8500", "discovery", bruno, 60)
    opportunity.call("Aménagement du jardin de la mairie", "mairie", "remi", "24000", "discovery", claire, 90)
    qualification = opportunity.call("Bureaux sur mesure", "durand", "ines", "15600", "qualification", bruno, 45)
    proposal = opportunity.call("Agencement de la boutique", "leroux", "paul", "12000", "discovery", claire, 30)
    opportunity.call("Entretien du parc automobile", "morel", "sarah", "6400", "negotiation", claire, 12)
    opportunity.call("Portail et clôture", "martin", nil, "3900", "proposal", bruno, 20)
    won = opportunity.call("Mobilier d'accueil", "leroux", "anne", "4800", "won", claire, -5)
    lost = opportunity.call("Pergola bioclimatique", "horizon", nil, "9800", "lost", bruno, -10)
    Api.move_opportunity(claire, won, Api::MoveInput.new(stage("won"))).value!
    reason = Api.loss_reasons(system).find! { |item| item.code == "competitor" }.id
    Api.move_opportunity(bruno, lost, Api::MoveInput.new(stage("lost"), reason, "Concurrent moins cher de 15 %")).value!

    # Un devis brouillon créé depuis l'opportunité : le prospect devient
    # client, l'opportunité passe à « Proposition ».
    Api.create_quote(claire, proposal).value!

    activity = ->(kind : String, subject : String, days : Int32, owner : Partiduo::Api::Actor, opportunity_id : Int64?, organization : String?) do
      input = Api::ActivityInput.new(kind: kind, subject: subject, due_on: today + days.days, owner_id: owner.user_id,
        opportunity_id: opportunity_id, organization_id: organization.try { |key| organizations[key] })
      Api.create_activity(owner, input).value!
    end
    activity.call("call", "Rappeler Paul Leroux au sujet du devis", -2, claire, proposal, nil)
    activity.call("email", "Envoyer les références de chantiers", 0, claire, nil, "mairie")
    activity.call("meeting", "Visite des bureaux", 3, bruno, qualification, nil)
    activity.call("task", "Préparer le chiffrage du fournil", -1, bruno, nil, "petit")
    activity.call("note", "Préfère être appelée le matin", 0, claire, nil, "morel")
  end
end

Marten.setup
CrmDemo.run
Marten::Server.setup
Marten::Server.start
