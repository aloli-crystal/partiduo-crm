# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Crm::SpecSupport
private alias Api = Crm::Api
private alias Cards = Partiduo::Api::Cards

describe "Relation client — organisations (ADR-009 D2)" do
  it "enregistre un prospect, contrôlé champ par champ, responsable par défaut : l'auteur" do
    S.setup
    view = S.organization("Menuiserie Leroux", siren: "732 829 320", email: "Contact@Leroux.test", city: "Tours",
      source_id: S.source("fair").id)
    view.prospect?.should be_true
    view.status_key.should eq("crm.organization_statuses.prospect")
    view.siren.should eq("732829320")
    view.email.should eq("contact@leroux.test")
    view.owner_id.should eq(S.user_id("alice@example.com"))

    result = Api.create_organization(S.seller, Api::OrganizationInput.new(name: " ", nature: "club", siren: "12",
      email: "sans-arobase", country_code: "France", owner_id: 999_i64, source_id: 999_i64))
    result.errors.map { |error| {error.field, error.key} }.should eq([
      {"siren", "crm.errors.organization.siren.invalid"},
      {"country_code", "crm.errors.organization.country_code.invalid"},
      {"name", "crm.errors.organization.name.blank"},
      {"nature", "crm.errors.organization.nature.invalid"},
      {"email", "crm.errors.organization.email.invalid"},
      {"source_id", "crm.errors.organization.source_id.unknown"},
      {"owner_id", "crm.errors.organization.owner_id.unknown"},
    ])
    Api.check_organization(S.seller, Api::OrganizationInput.new(name: "Correct")).success?.should be_true
  end

  it "filtre les organisations : texte, prospects, clients, responsable" do
    S.setup
    S.organization("Menuiserie Leroux", city: "Tours")
    S.organization("Boulangerie Petit", owner_id: S.user_id("bruno@example.com"))
    client = S.organization("Garage Morel")
    Api.become_customer(S.seller, client.id).value!
    Api.organizations(S.reader, Api::OrganizationQuery.new(search: "tours")).map(&.name).should eq(["Menuiserie Leroux"])
    Api.organizations(S.reader, Api::OrganizationQuery.new(status: "prospect")).map(&.name).should eq(["Boulangerie Petit", "Menuiserie Leroux"])
    Api.organizations(S.reader, Api::OrganizationQuery.new(status: "customer")).map(&.name).should eq(["Garage Morel"])
    Api.organizations(S.reader, Api::OrganizationQuery.new(owner_id: S.user_id("bruno@example.com"))).map(&.name).should eq(["Boulangerie Petit"])
  end

  it "fait devenir client par le contrat des fiches, sans fiche en double (card.saved)" do
    S.setup
    prospect = S.organization("Atelier Morel", siren: "443061841", email: "atelier@morel.test", line1: "3 rue du Port",
      postcode: "44100", city: "Nantes", country_code: "FR")
    Cards.cards(S.system, Cards::CardQuery.new(kind: "customer")).map(&.name).should_not contain("Atelier Morel")

    view = Api.become_customer(S.seller, prospect.id, Api::CustomerInput.new(nature: "business")).value!
    view.customer?.should be_true
    card = Cards.card(S.system, view.card_id || raise("absent"))
    card.name.should eq("Atelier Morel")
    card.kind.should eq("customer")
    card.siren.should eq("443061841")
    card.customer_nature.should eq("business")
    card.address.try(&.city).should eq("Nantes")
    Crm::Organization.all.count.should eq(1)
    Api.organization_for_card(S.reader, card.id).try(&.id).should eq(prospect.id)

    Api.become_customer(S.seller, prospect.id).error_keys.should eq(["crm.errors.organization.already_customer"])
    Api.become_customer(S.seller, S.organization("Autre").id, Api::CustomerInput.new(nature: "club"))
      .error_keys.should eq(["crm.errors.organization.nature.invalid"])
  end

  it "exige le droit d'écrire les fiches pour faire devenir client" do
    S.setup
    prospect = S.organization
    expect_raises(Partiduo::Api::Forbidden) { Api.become_customer(S.writer, prospect.id) }
    Api.organization(S.reader, prospect.id).prospect?.should be_true
  end

  it "fait apparaître dans le CRM une fiche client créée hors du CRM, et suit ses modifications" do
    S.setup
    category = Cards.category_by_code(S.system, "CUSTOMER") || raise("absent")
    card = Cards.create_card(S.system, Cards::CardInput.new(category_id: category.id, name: "Client Direct SA",
      siren: "552100554", email: "compta@direct.test", customer_nature: "business",
      address: Cards::AddressInput.new(line1: "1 place Carnot", postcode: "37000", city: "Tours", country_code: "FR"))).value!
    organization = Api.organization_for_card(S.reader, card.id) || raise("absent")
    organization.name.should eq("Client Direct SA")
    organization.customer?.should be_true
    organization.siren.should eq("552100554")
    organization.city.should eq("Tours")

    Cards.update_card(S.system, card.id, card.to_input.copy_with(name: "Client Direct", phone: "02 47 00 00 00")).value!
    updated = Api.organization(S.reader, organization.id)
    updated.name.should eq("Client Direct")
    updated.phone.should eq("02 47 00 00 00")
    Crm::Organization.all.count.should eq(1)

    # Un fournisseur n'est pas suivi par la relation client.
    supplier = Cards.category_by_code(S.system, "SUPPLIER") || raise("absent")
    Cards.create_card(S.system, Cards::CardInput.new(category_id: supplier.id, name: "Fournisseur")).value!
    Crm::Organization.all.count.should eq(1)
  end

  it "ne crée rien quand l'extension est inactive" do
    PartiduoUi::Reference.provision
    category = Cards.category_by_code(S.system, "CUSTOMER") || raise("absent")
    Cards.create_card(S.system, Cards::CardInput.new(category_id: category.id, name: "Client Hors CRM")).value!
    Crm::Organization.all.count.should eq(0)
  end

  it "supprime un prospect sans suite, garde une organisation cliente ou suivie (crm.admin)" do
    S.setup
    empty = S.organization("Vide")
    followed = S.organization("Suivie")
    S.contact("Durand", followed.id)
    expect_raises(Partiduo::Api::Forbidden) { Api.delete_organization(S.writer, empty.id) }
    Api.delete_organization(S.admin, followed.id).error_keys.should eq(["crm.errors.organization.in_use"])
    Api.delete_organization(S.admin, empty.id).success?.should be_true
    expect_raises(Partiduo::Api::NotFound) { Api.organization(S.reader, empty.id) }
  end
end
