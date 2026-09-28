# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Crm::SpecSupport
private alias Api = Crm::Api

private def activity(subject : String, due : Time, **options) : Api::ActivityView
  Api.create_activity(S.seller, Api::ActivityInput.new(**options.merge(kind: "call", subject: subject, due_on: due))).value!
end

describe "Relation client — activités à échéance (ADR-009 D4)" do
  it "range « Mes activités » : en retard, aujourd'hui, à venir ; les faites en sortent" do
    S.setup
    organization = S.organization
    late = activity("Rappeler", S.today - 2.days, organization_id: organization.id)
    today = activity("Envoyer la plaquette", S.today, organization_id: organization.id)
    upcoming = activity("Rendez-vous", S.today + 5.days, organization_id: organization.id, starts_at: SPEC_NOW + 5.days,
      duration_minutes: 90)
    activity("Pour Bruno", S.today, organization_id: organization.id, owner_id: S.user_id("bruno@example.com"))

    agenda = Api.agenda(S.seller)
    agenda.late.map(&.id).should eq([late.id])
    agenda.today.map(&.id).should eq([today.id])
    agenda.upcoming.map(&.id).should eq([upcoming.id])
    upcoming.duration_minutes.should eq(90)
    late.late?(S.today).should be_true
    Api.agenda(S.seller, S.user_id("bruno@example.com")).today.map(&.subject).should eq(["Pour Bruno"])
    Api.due_count(S.seller).should eq(2)

    done = Api.complete_activity(S.seller, late.id, report: "Client joint, rappel le 15.").value!
    done.done.should be_true
    done.done_at.should_not be_nil
    done.report.should eq("Client joint, rappel le 15.")
    Api.agenda(S.seller).late.should be_empty
    Api.due_count(S.seller).should eq(1)
    Api.complete_activity(S.seller, late.id, done: false).value!.done_at.should be_nil
  end

  it "contrôle la saisie : genre, objet, rattachement, durée ; une note est faite d'emblée" do
    S.setup
    result = Api.create_activity(S.seller, Api::ActivityInput.new(kind: "fax", subject: "", duration_minutes: -5))
    result.errors.map { |error| {error.field, error.key} }.should eq([
      {"base", "crm.errors.activity.target.missing"},
      {"duration_minutes", "crm.errors.activity.duration_minutes.range"},
      {"kind", "crm.errors.activity.kind.invalid"},
      {"subject", "crm.errors.activity.subject.blank"},
    ])
    note = Api.create_activity(S.seller, Api::ActivityInput.new(kind: "note", subject: "Préfère être appelé le matin",
      organization_id: S.organization.id)).value!
    note.done.should be_true
    note.due_on.should eq(S.today)
  end

  it "signale une opportunité ouverte sans activité à venir (« sans suite prévue »)" do
    S.setup
    opportunity = S.opportunity
    Api.opportunity(S.reader, opportunity.id).no_next_step?.should be_true
    activity("Déjà passée", S.today - 1.day, opportunity_id: opportunity.id)
    Api.opportunity(S.reader, opportunity.id).no_next_step?.should be_true
    next_step = activity("Démonstration", S.today + 7.days, opportunity_id: opportunity.id)
    view = Api.opportunity(S.reader, opportunity.id)
    view.no_next_step?.should be_false
    view.next_activity_on.should eq(S.today + 7.days)
    Api.complete_activity(S.seller, next_step.id).value!
    Api.opportunity(S.reader, opportunity.id).no_next_step?.should be_true
  end

  it "modifie et supprime une activité, liste par cible" do
    S.setup
    organization = S.organization
    view = activity("Appel", S.today, organization_id: organization.id)
    input = Api::ActivityInput.new(kind: "meeting", subject: "Rendez-vous sur place", due_on: S.today + 1.day,
      organization_id: organization.id, report: "À préparer")
    updated = Api.update_activity(S.writer, view.id, input).value!
    updated.kind_key.should eq("crm.activity_kinds.meeting")
    updated.organization_name.should eq("Menuiserie Leroux")
    Api.activities(S.reader, Api::ActivityQuery.new(organization_id: organization.id)).map(&.id).should eq([view.id])
    expect_raises(Partiduo::Api::Forbidden) { Api.delete_activity(S.reader, view.id) }
    Api.delete_activity(S.writer, view.id).success?.should be_true
    Api.activities(S.reader).should be_empty
  end
end
