# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Crm::SpecSupport
private alias Api = Crm::Api

private def menu_routes(entries : Array(Partiduo::Api::Modules::MenuView)) : Array(String?)
  entries.flat_map { |entry| [entry.route] + menu_routes(entry.children) }
end

describe "Extension CRM : manifeste et activation (ADR-003 D2, ADR-009 D1, D6, D7)" do
  it "déclare une extension conforme au contrat du cœur, qui dépend de la Facturation" do
    manifest = Partiduo::Modules[Crm::CODE]
    manifest.kind.should eq(Partiduo::Modules::Kind::Extension)
    manifest.version.should eq(Crm::VERSION)
    manifest.permissions.should eq(["crm.read", "crm.write", "crm.admin"])
    manifest.depends_on.should eq(["INVOICING"])
    manifest.subscribed_events.sort.should eq(["card.saved", "invoice.issued", "quote.decided"])
    manifest.uis.map(&.path).should eq(["ui/bulma"])
    manifest.menus.map { |menu| {menu.code, menu.parent, menu.route} }.should eq([
      {"CRM", nil, nil},
      {"CRM_DASHBOARD", "CRM", "crm:dashboard"},
      {"CRM_PIPELINE", "CRM", "crm:pipeline"},
      {"CRM_OPPORTUNITIES", "CRM", "crm:opportunities"},
      {"CRM_ACTIVITIES", "CRM", "crm:activities"},
      {"CRM_ORGANIZATIONS", "CRM", "crm:organizations"},
      {"CRM_CONTACTS", "CRM", "crm:contacts"},
      {"CRM_IMPORT", "CRM", "crm:import"},
      {"CRM_SETTINGS", "SETTINGS", "crm:settings"},
    ])
    Partiduo::Modules.structure_errors.should be_empty
    Partiduo::Modules.dependency_errors(manifest, Set{Crm::CODE, "INVOICING"}).should be_empty
    Partiduo::Modules.dependency_errors(manifest, Set{Crm::CODE}).should eq(["CRM requiert INVOICING, inactif"])
  end

  it "traduit son nom, ses permissions et ses menus en fr, en et nl" do
    manifest = Partiduo::Modules[Crm::CODE]
    keys = [manifest.name] + manifest.permission_entries.map(&.label) + manifest.menus.map(&.label)
    Partiduo::LOCALES.each do |locale|
      I18n.with_locale(locale) do
        keys.each { |key| I18n.t(key).should_not contain("missing") }
      end
    end
    I18n.with_locale("fr") { I18n.t("crm.menu.crm").should eq("Relation client") }
  end

  it "est inactive tant que l'instance ne l'active pas, puis se montre au menu « Relation client »" do
    PartiduoUi::Reference.provision
    S.user("alice@example.com", "Alice")
    S.user("bruno@example.com", "Bruno")
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.stages(S.reader) }
    Api.tile(S.reader).should be_nil
    Api.due_count(S.reader).should be_nil
    menu_routes(Partiduo::Api::Modules.menu(S.reader)).should_not contain("crm:pipeline")

    S.activate
    Partiduo::Modules.check!
    section = Partiduo::Api::Modules.menu(S.reader).find! { |item| item.code == "CRM" }
    section.label_key.should eq("crm.menu.crm")
    section.children.map(&.route).should eq(%w[crm:dashboard crm:pipeline crm:opportunities crm:activities
      crm:organizations crm:contacts])
    menu_routes(Partiduo::Api::Modules.menu(S.writer)).should contain("crm:import")
    menu_routes(Partiduo::Api::Modules.menu(S.admin)).should contain("crm:settings")
    menu_routes(Partiduo::Api::Modules.menu(Partiduo::Api::Actor.user(9_i64, [] of String))).should_not contain("crm:pipeline")
  end

  it "refuse de s'activer sans la Facturation" do
    with_active_modules("accounting") do
      PartiduoUi::Reference.provision
      result = Partiduo::Api::Modules.activate(Partiduo::Api::Actor.system, Crm::CODE)
      result.failure?.should be_true
    end
  end

  it "garde ses données désactivée, ses écrans et son contrat disparaissent" do
    S.setup
    S.opportunity
    Partiduo::Api::Modules.deactivate(Partiduo::Api::Actor.system, Crm::CODE).value!.active.should be_false
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.opportunities(S.reader) }
    Crm::Opportunity.all.count.should eq(1)
    S.activate
    Api.opportunities(S.reader).size.should eq(1)
  end

  it "installe les valeurs initiales : étapes, motifs de perte, origines (ADR-009 D3)" do
    S.setup
    stages = Api.stages(S.reader)
    I18n.with_locale("fr") do
      stages.map { |stage| {stage.label, stage.probability, stage.kind} }.should eq([
        {"Découverte", 10, "open"}, {"Qualification", 25, "open"}, {"Proposition", 50, "open"},
        {"Négociation", 75, "open"}, {"Gagnée", 100, "won"}, {"Perdue", 0, "lost"},
      ])
      Api.loss_reasons(S.reader).map(&.label).should contain("Concurrent retenu")
      Api.sources(S.reader).map(&.label).should eq(["Salon", "Site internet", "Recommandation", "Prospection", "Réseau", "Autre"])
    end
    I18n.with_locale("nl") { stages.first.label.should eq("Verkenning") }
  end
end
