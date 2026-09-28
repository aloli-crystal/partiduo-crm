# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Crm::SpecSupport
private alias Api = Crm::Api

# Dossier FR, exercice 2026, administrateur connecté (Alice), Bruno
# utilisateur du dossier, extension active.
private def signed_in : PartiduoUi::Browser
  browser = PartiduoUi::Books.admin
  S.user("bruno@example.com", "Bruno")
  S.activate
  browser
end

describe "Pipeline sous /ext/CRM/pipeline (ADR-009 D3)" do
  it "présente une colonne par étape, les cartes, montants et montants pondérés" do
    browser = signed_in
    first = S.opportunity("Agencement boutique", S.organization("Menuiserie Leroux").id, amount: "12000")
    S.opportunity("Vitrine", amount: "4000", stage_id: S.stage("proposal").id)
    html = browser.get("/ext/CRM/pipeline").html
    html.should contain("<h1>Pipeline")
    %w[Découverte Qualification Proposition Négociation Gagnée Perdue].each { |label| html.should contain(label) }
    html.should contain(%(id="crm-card-#{first.id}"))
    html.should contain(%(tabindex="0" data-crm-card="#{first.id}" draggable="true"))
    html.should contain("12\u202F000,00")
    html.should contain("Sans suite prévue")
    # Pipeline pondéré : 1 200 + 2 000.
    html.should contain(%(<strong class="pd-mono" data-crm-weighted>3\u202F200,00</strong>))
    # Déplacement sans JavaScript : boutons de formulaire, libellés pour les lecteurs d'écran.
    html.should contain(%(name="stage_id" value="#{S.stage("qualification").id}" data-crm-next))
    html.should contain("Déplacer vers « Qualification »")
    html.should contain("crm/js/pipeline.js")
    html.should contain(%(role="status" aria-live="polite" id="crm-board-status"))
    html.should contain("Maj+← et Maj+→")
  end

  it "déplace une carte par son bouton : formulaire ordinaire, puis HTMX qui ne rend que le tableau" do
    browser = signed_in
    view = S.opportunity
    response = browser.post("/ext/CRM/opportunities/#{view.id}/move", {"from" => "pipeline", "owner" => "",
                                                                       "stage_id" => S.stage("qualification").id.to_s})
    response.status.should eq(302)
    response.headers["Location"].should eq("/ext/CRM/pipeline")
    Api.opportunity(S.reader, view.id).stage.code.should eq("qualification")

    htmx = browser.htmx_post("/ext/CRM/opportunities/#{view.id}/move", {"from" => "pipeline", "owner" => "",
                                                                        "stage_id" => S.stage("proposal").id.to_s})
    htmx.status.should eq(200)
    htmx.html.should contain(%(id="crm-board"))
    htmx.html.should contain("« Agencement boutique » déplacée vers « Proposition ».")
    Api.opportunity(S.reader, view.id).stage.code.should eq("proposal")
    Api.stage_history(S.reader, view.id).last.user_id.should eq(S.user_id("alice@example.com"))
  end

  it "envoie vers « Changer d'étape » pour « Perdue », qui exige un motif relié au champ" do
    browser = signed_in
    view = S.opportunity
    lost = S.stage("lost").id
    response = browser.htmx_post("/ext/CRM/opportunities/#{view.id}/move", {"from" => "pipeline", "stage_id" => lost.to_s})
    response.headers["HX-Redirect"].should eq("/ext/CRM/opportunities/#{view.id}/move?stage=#{lost}")

    page = browser.get("/ext/CRM/opportunities/#{view.id}/move?stage=#{lost}").html
    page.should contain(%(<option value="#{lost}" selected>Perdue</option>))
    refused = browser.post("/ext/CRM/opportunities/#{view.id}/move", {"stage_id" => lost.to_s, "loss_reason_id" => "",
                                                                      "loss_note" => ""})
    refused.status.should eq(422)
    refused.html.should contain("Le motif de perte est obligatoire.")
    refused.html.should contain(%(aria-describedby="pd-f-loss-reason-id-help pd-f-loss-reason-id-errors" aria-invalid="true"))
    moved = browser.post("/ext/CRM/opportunities/#{view.id}/move", {"stage_id" => lost.to_s,
                                                                    "loss_reason_id" => S.reason("price").id.to_s, "loss_note" => "Trop cher"})
    moved.status.should eq(302)
    Api.opportunity(S.reader, view.id).loss_note.should eq("Trop cher")
  end

  it "ne propose aucun déplacement en lecture seule et refuse la commande (403)" do
    signed_in
    view = S.opportunity
    profile = PartiduoUi::Accounts.profile("Lecteur CRM", [Api::READ])
    PartiduoUi::Accounts.create("lecteur@example.com", profile_id: profile, profile: nil)
    reader = PartiduoUi::Accounts.signed_in("lecteur@example.com")
    html = reader.get("/ext/CRM/pipeline").html
    html.should contain("Consultation seule")
    html.should_not contain("data-crm-move")
    reader.post("/ext/CRM/opportunities/#{view.id}/move", {"from" => "pipeline", "stage_id" => S.stage("won").id.to_s})
      .status.should eq(403)
    reader.get("/ext/CRM/settings").status.should eq(403)
    Api.opportunity(S.reader, view.id).stage.code.should eq("discovery")
  end
end
