# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Crm::SpecSupport
private alias Api = Crm::Api

private CSV_FR = <<-CSV
  \uFEFFSociété;SIREN;Ville;Civilité;Prénom;Nom;Fonction;Courriel;Téléphone;Origine
  Menuiserie Leroux;732 829 320;Tours;M.;Paul;Leroux;Gérant;paul@leroux.test;02 47 00 00 01;Salon
  Menuiserie Leroux;732829320;Tours;Mme;Anne;Leroux;Comptable;anne@leroux.test;;Salon
  Boulangerie Petit;;Amboise;;Luc;Petit;;luc@petit.test;;Site internet
  Garage Morel;552100554;Blois;;;;;;;
  ;;;;;;;;;
  Doublon courriel;;;;Jean;Durand;;paul@leroux.test;;
  Mauvais SIREN;12;;;;;;;;
  CSV

describe "Relation client — import et export CSV (ADR-009 D8)" do
  it "propose la correspondance des colonnes d'après les en-têtes (fr, en, nl) et reconnaît le séparateur" do
    S.setup
    preview = Api.preview_import(S.writer, Api::ImportInput.new(CSV_FR)).value!
    preview.separator.should eq(';')
    preview.headers.first.should eq("Société")
    preview.mapping.should eq({
      "Société" => "organization_name", "SIREN" => "organization_siren", "Ville" => "organization_city",
      "Civilité" => "contact_civility", "Prénom" => "contact_first_name", "Nom" => "contact_last_name",
      "Fonction" => "contact_job_title", "Courriel" => "contact_email", "Téléphone" => "contact_phone", "Origine" => "source",
    })
    english = Api.preview_import(S.writer, Api::ImportInput.new("Company,First name,Last name,Email\nAcme,Jane,Doe,jane@acme.test\n")).value!
    english.separator.should eq(',')
    english.mapping.values.should eq(%w[organization_name contact_first_name contact_last_name contact_email])
    dutch = Api.preview_import(S.writer, Api::ImportInput.new("Bedrijf\tVoornaam\tAchternaam\tGemeente\nBakkerij Peeters\tJan\tPeeters\tGent\n")).value!
    dutch.separator.should eq('\t')
    dutch.mapping.values.should eq(%w[organization_name contact_first_name contact_last_name organization_city])
  end

  it "signale en aperçu les doublons (SIREN, courriel, nom) et les erreurs, sans rien enregistrer" do
    S.setup
    S.organization("Garage Morel", siren: "552100554")
    preview = Api.preview_import(S.writer, Api::ImportInput.new(CSV_FR)).value!
    preview.rows.map { |row| {row.line, row.duplicate, row.errors.map(&.key)} }.should eq([
      {2, nil, [] of String},
      {3, nil, [] of String},
      {4, nil, [] of String},
      {5, "siren", [] of String},
      {7, "file_email", [] of String},
      {8, nil, ["crm.errors.organization.siren.invalid"]},
    ])
    preview.rows[3].duplicate_of.should eq("Garage Morel")
    preview.rows[4].duplicate_of.should eq("2")
    preview.rows[5].errors.first.field.should eq("organization_siren")
    preview.importable_count.should eq(3)
    Crm::Contact.all.count.should eq(0)
  end

  it "importe les lignes valables : une organisation par nom, contacts rattachés, origine et base légale" do
    S.setup
    input = Api::ImportInput.new(CSV_FR, legal_basis: "legitimate_interest")
    report = Api.import(S.writer, input).value!
    report.organizations.should eq(3)
    report.contacts.should eq(3)
    report.skipped.map(&.line).should eq([7, 8])
    leroux = Api.organizations(S.reader, Api::OrganizationQuery.new(search: "Leroux")).first
    leroux.siren.should eq("732829320")
    leroux.owner_id.should eq(S.user_id("bruno@example.com"))
    contacts = Api.contacts(S.reader, Api::ContactQuery.new(organization_id: leroux.id))
    contacts.map { |contact| {contact.full_name, contact.civility, contact.legal_basis} }.should eq([
      {"Anne Leroux", "ms", "legitimate_interest"}, {"Paul Leroux", "mr", "legitimate_interest"},
    ])
    contacts.first.source_id.should eq(S.source("fair").id)
    Api.contacts(S.reader, Api::ContactQuery.new(search: "Petit")).first.source_id.should eq(S.source("website").id)

    # Le même fichier une seconde fois : tout est doublon.
    again = Api.import(S.writer, input).value!
    {again.organizations, again.contacts}.should eq({0, 0})
  end

  it "applique la correspondance choisie et refuse une correspondance incohérente" do
    S.setup
    content = "A;B\nPetit;Luc\n"
    Api.preview_import(S.writer, Api::ImportInput.new(content)).error_keys.should eq(["crm.errors.import.mapping.name_missing"])
    mapping = {"A" => "contact_last_name", "B" => "contact_first_name"}
    report = Api.import(S.writer, Api::ImportInput.new(content, mapping)).value!
    report.contacts.should eq(1)
    Api.contacts(S.reader).first.full_name.should eq("Luc Petit")
    Api.preview_import(S.writer, Api::ImportInput.new(content, {"A" => "contact_last_name", "B" => "contact_last_name"}))
      .error_keys.should eq(["crm.errors.import.mapping.twice"])
    Api.preview_import(S.writer, Api::ImportInput.new(content, {"A" => "salaire"})).error_keys.should eq(["crm.errors.import.mapping.invalid"])
    Api.preview_import(S.writer, Api::ImportInput.new("")).error_keys.should eq(["crm.errors.import.content.empty"])
    expect_raises(Partiduo::Api::Forbidden) { Api.import(S.reader, Api::ImportInput.new(content, mapping)) }
  end

  it "exporte les contacts pour une action commerciale, en-têtes traduits" do
    S.setup
    S.contact("Leroux", S.organization.id, first_name: "Paul", email: "paul@leroux.test", legal_basis: "consent")
    csv = I18n.with_locale("fr") { Api.export_contacts(S.reader) }
    lines = csv.lchop('\uFEFF').lines
    lines.first.should eq("Civilité;Prénom;Nom;Fonction;Courriel;Téléphone;Mobile;Organisation;Base légale")
    lines[1].should eq(";Paul;Leroux;;paul@leroux.test;;;Menuiserie Leroux;Consentement")
  end
end
