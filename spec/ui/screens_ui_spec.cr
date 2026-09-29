# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Crm::SpecSupport
private alias Api = Crm::Api

private def signed_in : PartiduoUi::Browser
  browser = PartiduoUi::Books.admin
  S.user("bruno@example.com", "Bruno")
  S.activate
  browser
end

describe "Écrans de la relation client sous /ext/CRM/ (ADR-009, ADR-005)" do
  it "est montée sous le code de l'extension, avec ses permissions par route" do
    Marten.routes.reverse("crm:dashboard").should eq("/ext/CRM/dashboard")
    Marten.routes.reverse("crm:opportunity", id: 4).should eq("/ext/CRM/opportunities/4")
    mount = PartiduoUi::Extensions["CRM"]? || raise("interface non montée")
    mount.permission.should eq("crm.read")
    mount.permission_for("crm:opportunity_move").should eq("crm.write")
    mount.permission_for("crm:import").should eq("crm.write")
    mount.permission_for("crm:settings").should eq("crm.admin")
    mount.permission_for("crm:contact_erase").should eq("crm.admin")
    mount.permission_for("crm:pipeline").should eq("crm.read")
  end

  it "n'existe pas tant que l'extension est inactive (404) et renvoie un anonyme vers la connexion" do
    browser = PartiduoUi::Books.admin
    browser.get("/ext/CRM/pipeline").status.should eq(404)
    S.activate
    response = PartiduoUi::Browser.new.get("/ext/CRM/pipeline")
    response.status.should eq(302)
    response.headers["Location"].should eq("/login?next=%2Fext%2FCRM%2Fpipeline")
  end

  it "ajoute la rubrique « Relation client » au menu, la tuile « Commercial » et « À traiter » au tableau de bord" do
    browser = signed_in
    S.opportunity("Agencement", amount: "10000")
    Api.create_activity(S.seller, Api::ActivityInput.new(kind: "call", subject: "Rappeler", due_on: S.today - 1.day,
      organization_id: S.organization("Autre").id)).value!
    dashboard = browser.get("/").html
    dashboard.should contain(%(<p class="menu-label" id="pd-menu-CRM">Relation client</p>))
    dashboard.should contain(%(href="/ext/CRM/pipeline"))
    dashboard.should contain(%(<span class="pd-count" data-pd-count="CRM_ACTIVITIES">1</span>))
    dashboard.should contain(%(data-module="CRM"))
    dashboard.should contain("Commercial")
    dashboard.should contain("1\u202F000,00")
    dashboard.should contain("pipeline pondéré, 1 opportunité ouverte")
    dashboard.should contain("1 activité en retard")
    dashboard.should contain("1 activité commerciale à faire")
  end

  it "ajoute aussi la tuile « Commercial » aux tableaux de bord simplifiés (point d'accroche de l'interface)" do
    browser = signed_in
    S.opportunity("Agencement", amount: "10000")
    Partiduo::Api::Modules.deactivate(S.system, "ANALYTIC").success?.should be_true
    Partiduo::Api::Modules.deactivate(S.system, "ACCOUNTING").success?.should be_true
    Partiduo::Api::Modules.activate(S.system, "LIBERAL").success?.should be_true
    Partiduo::Api::Liberal.load_defaults(S.system)
    liberal = browser.get("/").html
    liberal.should contain(%(href="/liberal/receipts"))
    liberal.should contain(%(data-module="CRM"))
    liberal.should contain("pipeline pondéré, 1 opportunité ouverte")

    Partiduo::Api::Modules.activate(S.system, "MICRO").success?.should be_true
    Partiduo::Api::Micro.load_defaults(S.system)
    micro = browser.get("/").html
    micro.should contain(%(href="/micro/receipts"))
    micro.should contain(%(data-module="CRM"))
    micro.should contain("1\u202F000,00")
  end

  it "n'ajoute pas la tuile quand l'extension est inactive" do
    browser = PartiduoUi::Books.admin
    browser.get("/").html.should_not contain(%(data-module="CRM"))
  end

  it "affiche le tableau de bord commercial sur une période" do
    browser = signed_in
    won = S.opportunity("Gagnée", amount: "7000")
    Api.move_opportunity(S.writer, won.id, Api::MoveInput.new(S.stage("won").id)).value!
    S.opportunity("Ouverte", amount: "10000")
    browser.get("/ext/CRM/").headers["Location"].should eq("/ext/CRM/dashboard")
    html = browser.get("/ext/CRM/dashboard?from=2026-01-01&to=2026-12-31").html
    html.should contain("<h1>Tableau de bord commercial")
    html.should contain("Pipeline pondéré")
    html.should contain("7\u202F000,00")
    html.should contain("100 %")
    html.should contain("Facturé issu des opportunités")
    html.should contain(%(<progress class="progress is-primary is-small mb-0" max="100" value="100"))
    html.should contain("Alice Martin")
  end

  it "crée une organisation, relie les erreurs aux champs, la fait devenir cliente" do
    browser = signed_in
    browser.get("/ext/CRM/organizations/new").html.should contain("Une nouvelle organisation est un prospect")
    refused = browser.post("/ext/CRM/organizations/new", {"name" => "", "nature" => "business", "siren" => "12", "email" => "x"})
    refused.status.should eq(422)
    refused.html.should contain("Le nom de l'organisation est obligatoire.")
    refused.html.should contain(%(id="pd-f-siren-errors"))
    refused.html.should contain(%(aria-describedby="pd-f-siren-errors" aria-invalid="true"))
    created = browser.post("/ext/CRM/organizations/new", {"name" => "Atelier Morel", "nature" => "business",
                                                          "siren" => "443 061 841", "city" => "Nantes", "owner_id" => "", "source_id" => ""})
    created.status.should eq(302)
    organization = Api.organizations(S.reader).first
    created.headers["Location"].should eq("/ext/CRM/organizations/#{organization.id}")
    page = browser.follow(created).html
    page.should contain("Organisation créée.")
    page.should contain("Prospect")
    page.should contain("Devenir client")

    browser.get("/ext/CRM/organizations/#{organization.id}/customer").html.should contain("« Atelier Morel » va devenir cliente")
    done = browser.post("/ext/CRM/organizations/#{organization.id}/customer", {"nature" => "business", "category_id" => ""})
    done.status.should eq(302)
    Api.organization(S.reader, organization.id).customer?.should be_true
    list = browser.get("/ext/CRM/organizations?status=customer").html
    list.should contain("Atelier Morel")
    csv = browser.get("/ext/CRM/organizations?format=csv")
    csv.content_type.should contain("text/csv")
    csv.content.should contain("Atelier Morel")
  end

  it "crée une opportunité par le formulaire, la consulte, crée son devis vers la Facturation" do
    browser = signed_in
    organization = S.organization("Menuiserie Leroux", siren: "732829320")
    form = browser.get("/ext/CRM/opportunities/new?organization=#{organization.id}").html
    form.should contain(%(<option value="#{organization.id}" selected>Menuiserie Leroux</option>))
    refused = browser.post("/ext/CRM/opportunities/new", {"title" => "", "organization_id" => organization.id.to_s,
                                                          "amount" => "douze"})
    refused.status.should eq(422)
    refused.html.should contain("Indiquez un nombre")
    created = browser.post("/ext/CRM/opportunities/new", {"title" => "Agencement boutique", "organization_id" => organization.id.to_s,
                                                          "contact_id" => "", "amount" => "12 000,50", "probability" => "",
                                                          "expected_close_on" => "2026-11-30", "owner_id" => "", "source_id" => "",
                                                          "stage_id" => S.stage("qualification").id.to_s})
    created.status.should eq(302)
    view = Api.opportunities(S.reader).first
    {view.amount, view.stage.code, view.expected_close_on}.should eq({S.d("12000.50"), "qualification", S.date("2026-11-30")})
    page = browser.get("/ext/CRM/opportunities/#{view.id}").html
    page.should contain("Historique des étapes")
    page.should contain("Créer un devis")
    page.should contain("Aucun devis pour l'instant.")

    quote = browser.post("/ext/CRM/opportunities/#{view.id}/quote")
    quote.status.should eq(302)
    document = Api.documents(S.seller, view.id).first
    quote.headers["Location"].should eq("/invoicing/documents/#{document.document_id}/edit")
    browser.get("/ext/CRM/opportunities/#{view.id}").html.should contain("brouillon")
    Api.opportunity(S.reader, view.id).stage.code.should eq("proposal")

    list = browser.get("/ext/CRM/opportunities?status=all").html
    list.should contain("Agencement boutique")
    browser.get("/ext/CRM/opportunities?status=lost").html.should_not contain("Agencement boutique")
  end

  it "gère les contacts : consentement, opposition, effacement réservé à l'administrateur, export" do
    browser = signed_in
    organization = S.organization
    created = browser.post("/ext/CRM/contacts/new", {"last_name" => "Leroux", "first_name" => "Paul", "civility" => "mr",
                                                     "organization_id" => organization.id.to_s, "email" => "paul@leroux.test",
                                                     "legal_basis" => "consent", "legal_basis_on" => "2026-09-01", "source_id" => ""})
    created.status.should eq(302)
    contact = Api.contacts(S.reader).first
    contact.legal_basis_on.should eq(S.date("2026-09-01"))
    page = browser.get("/ext/CRM/contacts/#{contact.id}").html
    page.should contain("Consentement (RGPD)")
    page.should contain("Enregistrer l'opposition")
    page.should contain("Effacer (RGPD)")

    export = browser.get("/ext/CRM/contacts/export")
    export.content.should contain("paul@leroux.test")
    browser.post("/ext/CRM/contacts/#{contact.id}/opposition").status.should eq(302)
    browser.get("/ext/CRM/contacts").html.should_not contain("paul@leroux.test")
    browser.get("/ext/CRM/contacts?tab=opposed").html.should contain("paul@leroux.test")
    browser.get("/ext/CRM/contacts/export").content.should_not contain("paul@leroux.test")

    profile = PartiduoUi::Accounts.profile("Commercial", [Api::READ, Api::WRITE])
    PartiduoUi::Accounts.create("commercial@example.com", profile_id: profile, profile: nil)
    seller = PartiduoUi::Accounts.signed_in("commercial@example.com")
    seller.get("/ext/CRM/contacts/#{contact.id}").html.should_not contain("Effacer (RGPD)")
    seller.post("/ext/CRM/contacts/#{contact.id}/erase").status.should eq(403)
    browser.post("/ext/CRM/contacts/#{contact.id}/erase").headers["Location"].should eq("/ext/CRM/contacts")
    Crm::Contact.all.count.should eq(0)
  end

  it "range « Mes activités » en retard, aujourd'hui, à venir, et marque une activité faite" do
    browser = signed_in
    organization = S.organization
    late = Api.create_activity(S.seller, Api::ActivityInput.new(kind: "call", subject: "Rappeler Paul", due_on: S.today - 3.days,
      organization_id: organization.id)).value!
    created = browser.post("/ext/CRM/activities/new", {"kind" => "meeting", "subject" => "Rendez-vous atelier",
                                                       "due_on" => "2026-10-02", "starts_at" => "14:30", "duration_minutes" => "90",
                                                       "owner_id" => "", "report" => "", "organization_id" => organization.id.to_s,
                                                       "contact_id" => "", "opportunity_id" => ""})
    created.status.should eq(302)
    upcoming = Api.agenda(S.seller).upcoming.first
    upcoming.starts_at.should eq(Time.utc(2026, 10, 2, 14, 30))
    refused = browser.post("/ext/CRM/activities/new", {"kind" => "call", "subject" => "", "due_on" => "2026-10-02",
                                                       "starts_at" => "25h", "organization_id" => ""})
    refused.status.should eq(422)
    refused.html.should contain("Indiquez une heure au format 10:30.")

    html = browser.get("/ext/CRM/activities").html
    html.should contain(%(data-crm-group="late"))
    html.should contain("Rappeler Paul")
    html.should contain("Rendez-vous atelier")
    html.should contain("90 minutes")
    browser.post("/ext/CRM/activities/#{late.id}/done", {"next" => "/ext/CRM/activities"}).status.should eq(302)
    Api.activity(S.reader, late.id).done.should be_true
  end

  it "importe un fichier CSV : aperçu, correspondance ajustable, doublons signalés, bilan" do
    browser = signed_in
    S.organization("Garage Morel", siren: "552100554")
    content = "Société;SIREN;Prénom;Nom;Courriel\nMenuiserie Leroux;732829320;Paul;Leroux;paul@leroux.test\n" \
              "Garage Morel;552100554;;;\n"
    browser.get("/ext/CRM/import").html.should contain("Champs reconnus")
    preview = browser.post("/ext/CRM/import", {"step" => "preview", "content" => content, "legal_basis" => "legitimate_interest",
                                               "source_id" => ""})
    preview.status.should eq(200)
    html = preview.html
    html.should contain("Correspondance des colonnes")
    html.should contain(%(<option value="organization_name" selected>Organisation</option>))
    html.should contain("Doublon : même SIREN que « Garage Morel »")
    html.should contain("2 lignes, 1 à importer")
    html.should contain("Importer 1 ligne")

    report = browser.post("/ext/CRM/import", {"step" => "import", "mapped" => "1", "content" => content,
                                              "legal_basis" => "legitimate_interest", "source_id" => "", "map_0" => "organization_name",
                                              "map_1" => "organization_siren", "map_2" => "contact_first_name",
                                              "map_3" => "contact_last_name", "map_4" => "contact_email"})
    report.status.should eq(200)
    report.html.should contain("1 organisation(s) et 1 contact(s) créés.")
    report.html.should contain("Lignes écartées")
    Api.contacts(S.reader).first.legal_basis.should eq("legitimate_interest")
    browser.post("/ext/CRM/import", {"step" => "preview", "content" => ""}).status.should eq(422)
  end

  it "paramètre les étapes (crm.admin) : ajout, erreurs reliées à la ligne" do
    browser = signed_in
    html = browser.get("/ext/CRM/settings").html
    html.should contain("Étapes du pipeline")
    html.should contain("Motifs de perte")
    html.should contain("Origines")
    created = browser.post("/ext/CRM/settings/stages", {"name" => "Démonstration", "probability" => "40", "position" => "35",
                                                        "active" => "1"})
    created.status.should eq(302)
    Api.stages(S.reader).map(&.label).should contain("Démonstration")
    refused = browser.post("/ext/CRM/settings/reasons", {"name" => "", "position" => "5", "active" => "1"})
    refused.status.should eq(422)
    refused.html.should contain(%(id="crm-reasons-new-errors"))
    refused.html.should contain("Le libellé est obligatoire.")
    browser.post("/ext/CRM/settings/unknown", {"name" => "x"}).status.should eq(404)
  end
end
