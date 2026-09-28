# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Crm::SpecSupport
private alias Api = Crm::Api
private alias Inv = Partiduo::Api::Invoicing

describe "Relation client — de l'opportunité au devis, événements du cœur (ADR-009 D5)" do
  it "crée un devis depuis un prospect : il devient client, le devis est lié, l'opportunité passe à « Proposition »" do
    S.setup
    organization = S.organization("Atelier Morel", siren: "443061841", city: "Nantes")
    opportunity = S.opportunity("Rénovation vitrine", organization.id)

    quote = Api.create_quote(S.seller, opportunity.id).value!
    quote.kind.should eq("quote")
    quote.draft?.should be_true
    quote.lines.map(&.description).should eq(["Rénovation vitrine"])
    customer = Api.organization(S.reader, organization.id)
    customer.customer?.should be_true
    quote.customer_card_id.should eq(customer.card_id)

    view = Api.opportunity(S.reader, opportunity.id)
    view.stage.code.should eq("proposal")
    view.probability.should eq(50)
    Api.stage_history(S.reader, opportunity.id).last.cause.should eq("quote_created")
    documents = Api.documents(S.seller, opportunity.id)
    documents.map { |document| {document.document_id, document.kind, document.readable} }.should eq([{quote.id, "quote", true}])
    documents.first.status.should eq("draft")
    # Sans droit de lecture de la Facturation : lien connu, contenu non lu.
    Api.documents(S.reader, opportunity.id).first.readable.should be_false

    # Seconde version : l'étape ne recule pas depuis « Négociation ».
    Api.move_opportunity(S.writer, opportunity.id, Api::MoveInput.new(S.stage("negotiation").id)).value!
    Api.create_quote(S.seller, opportunity.id).value!
    Api.opportunity(S.reader, opportunity.id).stage.code.should eq("negotiation")
    Api.documents(S.seller, opportunity.id).size.should eq(2)
    Crm::Organization.all.count.should eq(1)
  end

  it "exige le droit d'écrire dans la Facturation (et les fiches pour un prospect), refuse une opportunité close" do
    S.setup
    opportunity = S.opportunity
    expect_raises(Partiduo::Api::Forbidden) { Api.create_quote(S.writer, opportunity.id) }
    no_cards = Partiduo::Api::Actor.user(S.user_id("bruno@example.com"), [Api::READ, Api::WRITE, Inv::WRITE, "cards.card.read"])
    expect_raises(Partiduo::Api::Forbidden) { Api.create_quote(no_cards, opportunity.id) }
    Crm::DocumentLink.all.count.should eq(0)
    Api.organization(S.reader, opportunity.organization_id).prospect?.should be_true

    Api.move_opportunity(S.writer, opportunity.id, Api::MoveInput.new(S.stage("won").id)).value!
    Api.create_quote(S.seller, opportunity.id).error_keys.should eq(["crm.errors.opportunity.closed"])
  end

  it "passe l'opportunité à « Gagnée » quand le devis est accepté (quote.decided)" do
    S.setup
    opportunity = S.opportunity
    quote = S.issue_quote(Api.create_quote(S.seller, opportunity.id).value!)
    quote.status.should eq("sent")
    S.capture("quote.decided") do |events|
      Inv.decide_quote(S.seller, quote.id, "accepted").value!
      events.map(&.["decision"]).should eq(["accepted"])
    end
    view = Api.opportunity(S.reader, opportunity.id)
    view.status.should eq("won")
    view.closed_at.should_not be_nil
    change = Api.stage_history(S.reader, opportunity.id).last
    {change.to_stage.code, change.cause, change.user_id}.should eq({"won", "quote_accepted", S.user_id("alice@example.com")})
  end

  it "laisse l'opportunité ouverte et crée une activité « relancer » quand le devis est refusé" do
    S.setup
    opportunity = S.opportunity(owner_id: S.user_id("bruno@example.com"))
    quote = S.issue_quote(Api.create_quote(S.seller, opportunity.id).value!)
    Inv.decide_quote(S.seller, quote.id, "refused").value!
    view = Api.opportunity(S.reader, opportunity.id)
    view.status.should eq("open")
    view.stage.code.should eq("proposal")
    activity = Api.activities(S.reader, Api::ActivityQuery.new(opportunity_id: opportunity.id)).first
    activity.kind.should eq("task")
    activity.subject.should eq("Relancer : devis #{quote.number} refusé")
    activity.owner_id.should eq(S.user_id("bruno@example.com"))
    activity.due_on.should eq(S.today + 3.days)
    activity.done.should be_false
    view.no_next_step?.should be_false
  end

  it "ignore la décision sur un devis qui n'est pas lié à une opportunité" do
    S.setup
    organization = S.organization
    Api.become_customer(S.seller, organization.id).value!
    card_id = Api.organization(S.reader, organization.id).card_id || raise("absent")
    quote = Inv.create_document(S.system, Inv::DocumentInput.new(kind: "quote", customer_card_id: card_id)).value!
    quote = S.issue_quote(quote)
    Inv.decide_quote(S.seller, quote.id, "accepted").success?.should be_true
    Crm::Activity.all.count.should eq(0)
  end

  it "rattache à l'opportunité la facture tirée de son devis (invoice.issued), et la compte au tableau de bord" do
    S.setup
    opportunity = S.opportunity(organization_id: S.organization("Atelier Morel", siren: "443061841").id)
    quote = S.issue_quote(Api.create_quote(S.seller, opportunity.id).value!, "12000")
    Inv.decide_quote(S.seller, quote.id, "accepted").value!
    order = Inv.transform(S.system, quote.id, Inv::TransformInput.new("order")).value!
    order = Inv.issue(S.system, order.id).value!
    invoice = Inv.transform(S.system, order.id, Inv::TransformInput.new("invoice")).value!
    Api.documents(S.seller, opportunity.id).map(&.kind).should eq(["quote"])
    invoice = Inv.issue(S.system, invoice.id).value!

    documents = Api.documents(S.seller, opportunity.id)
    documents.map(&.kind).should eq(["quote", "invoice"])
    documents.last.number.should eq(invoice.number)
    documents.last.total_net.should eq(S.d("12000"))

    board = Api.dashboard(S.seller)
    board.invoiced.should eq(S.d("12000"))
    board.invoiced_count.should eq(1)
    Api.dashboard(S.reader).invoiced.should be_nil
  end
end
