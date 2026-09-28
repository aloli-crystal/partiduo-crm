# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Crm::SpecSupport
private alias Api = Crm::Api

describe "Relation client — contacts et consentement (ADR-009 D2, RGPD)" do
  it "enregistre un contact, rattaché ou isolé, avec sa base légale datée" do
    S.setup
    organization = S.organization
    contact = S.contact("Leroux", organization.id, first_name: "Paul", civility: "mr", job_title: "Gérant",
      email: "Paul@Leroux.test", source_id: S.source("fair").id, legal_basis: "legitimate_interest")
    contact.full_name.should eq("Paul Leroux")
    contact.organization_name.should eq("Menuiserie Leroux")
    contact.email.should eq("paul@leroux.test")
    contact.legal_basis_on.should eq(S.today)
    contact.legal_basis_key.should eq("crm.legal_bases.legitimate_interest")
    S.contact("Isolé").organization_id.should be_nil

    result = Api.create_contact(S.seller, Api::ContactInput.new(last_name: "", civility: "dr", legal_basis: "hunch",
      email: "x", organization_id: 999_i64))
    result.errors.map { |error| {error.field, error.key} }.should eq([
      {"organization_id", "crm.errors.contact.organization_id.unknown"},
      {"legal_basis", "crm.errors.contact.legal_basis.invalid"},
      {"civility", "crm.errors.contact.civility.invalid"},
      {"last_name", "crm.errors.contact.last_name.blank"},
      {"email", "crm.errors.contact.email.invalid"},
    ])
  end

  it "écarte un contact opposé des listes d'actions commerciales, de l'export et des nouvelles actions" do
    S.setup
    organization = S.organization
    kept = S.contact("Garde", organization.id, email: "garde@test.test")
    opposed = S.contact("Oppose", organization.id, email: "oppose@test.test", legal_basis: "consent")
    activity = Api.create_activity(S.seller, Api::ActivityInput.new(kind: "call", subject: "Appeler", contact_id: opposed.id)).value!

    view = Api.record_opposition(S.seller, opposed.id, "Demande par courriel").value!
    view.opposed?.should be_true
    view.opposed_at.should_not be_nil
    view.opposition_note.should eq("Demande par courriel")
    Api.record_opposition(S.seller, opposed.id).error_keys.should eq(["crm.errors.contact.already_opposed"])

    Api.contacts(S.reader).map(&.last_name).should eq(["Garde"])
    Api.contacts(S.reader, Api::ContactQuery.new(opposed: true)).map(&.last_name).should eq(["Oppose"])
    Api.contacts(S.reader, Api::ContactQuery.new(opposed: nil)).size.should eq(2)
    csv = Api.export_contacts(S.reader)
    csv.should contain("garde@test.test")
    csv.should_not contain("oppose@test.test")
    Api.agenda(S.seller).today.map(&.id).should_not contain(activity.id)

    Api.create_opportunity(S.seller, Api::OpportunityInput.new(title: "Nouvelle", organization_id: organization.id,
      contact_id: opposed.id)).error_keys.should eq(["crm.errors.opportunity.contact_id.opposed"])
    Api.create_activity(S.seller, Api::ActivityInput.new(kind: "email", subject: "Relance", contact_id: opposed.id))
      .error_keys.should eq(["crm.errors.activity.contact_id.opposed"])
    Api.create_opportunity(S.seller, Api::OpportunityInput.new(title: "Autre", organization_id: organization.id,
      contact_id: kept.id)).success?.should be_true

    # Levée de l'opposition : par l'administrateur, base légale à rétablir.
    expect_raises(Partiduo::Api::Forbidden) { Api.withdraw_opposition(S.writer, opposed.id) }
    lifted = Api.withdraw_opposition(S.admin, opposed.id).value!
    lifted.opposed?.should be_false
    lifted.legal_basis.should eq("")
    Api.withdraw_opposition(S.admin, opposed.id).error_keys.should eq(["crm.errors.contact.not_opposed"])
  end

  it "refuse un contact d'une autre organisation comme contact principal" do
    S.setup
    first = S.organization("Première")
    second = S.organization("Seconde")
    stranger = S.contact("Étranger", second.id)
    Api.create_opportunity(S.seller, Api::OpportunityInput.new(title: "Affaire", organization_id: first.id,
      contact_id: stranger.id)).error_keys.should eq(["crm.errors.opportunity.contact_id.other_organization"])
  end

  it "efface un contact (crm.admin) tant qu'il n'est lié à aucun devis" do
    S.setup
    organization = S.organization
    contact = S.contact("Efface", organization.id, email: "efface@test.test")
    opportunity = S.opportunity(organization_id: organization.id, contact_id: contact.id)
    own = Api.create_activity(S.seller, Api::ActivityInput.new(kind: "call", subject: "Personnel", contact_id: contact.id)).value!
    shared = Api.create_activity(S.seller, Api::ActivityInput.new(kind: "meeting", subject: "Réunion", contact_id: contact.id,
      opportunity_id: opportunity.id)).value!

    expect_raises(Partiduo::Api::Forbidden) { Api.erase_contact(S.writer, contact.id) }
    Api.contact_quoted?(S.reader, contact.id).should be_false
    Api.erase_contact(S.admin, contact.id).success?.should be_true
    expect_raises(Partiduo::Api::NotFound) { Api.contact(S.reader, contact.id) }
    expect_raises(Partiduo::Api::NotFound) { Api.activity(S.reader, own.id) }
    Api.activity(S.reader, shared.id).contact_id.should be_nil
    Api.opportunity(S.reader, opportunity.id).contact_id.should be_nil

    quoted = S.contact("Devis", organization.id)
    with_quote = S.opportunity("Avec devis", organization.id, contact_id: quoted.id)
    Api.create_quote(S.seller, with_quote.id).value!
    Api.contact_quoted?(S.reader, quoted.id).should be_true
    Api.erase_contact(S.admin, quoted.id).error_keys.should eq(["crm.errors.contact.quoted"])
  end
end
