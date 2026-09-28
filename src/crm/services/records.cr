# SPDX-License-Identifier: AGPL-3.0-or-later

module Crm
  # Lecture des lignes et construction des vues du contrat (interne).
  module Records
    alias Api = Crm::Api

    def self.today : Time
      Partiduo::Api::Core.today
    end

    def self.error(field : String, key : String, params : Hash(String, String) = {} of String => String) : Partiduo::Api::FieldError
      Partiduo::Api::FieldError.new(field, "crm.errors.#{key}", params)
    end

    # --- Recherche ---------------------------------------------------------------

    def self.organization!(id : Int64, lock : Bool = false) : Organization
      query = Organization.filter(id: id)
      query = query.lock if lock
      query.first || raise Partiduo::Api::NotFound.new("crm_organization", id)
    end

    def self.contact!(id : Int64, lock : Bool = false) : Contact
      query = Contact.filter(id: id)
      query = query.lock if lock
      query.first || raise Partiduo::Api::NotFound.new("crm_contact", id)
    end

    def self.opportunity!(id : Int64, lock : Bool = false) : Opportunity
      query = Opportunity.filter(id: id)
      query = query.lock if lock
      query.first || raise Partiduo::Api::NotFound.new("crm_opportunity", id)
    end

    def self.activity!(id : Int64, lock : Bool = false) : Activity
      query = Activity.filter(id: id)
      query = query.lock if lock
      query.first || raise Partiduo::Api::NotFound.new("crm_activity", id)
    end

    def self.stage!(id : Int64) : Stage
      Stage.filter(id: id).first || raise Partiduo::Api::NotFound.new("crm_stage", id)
    end

    # Étapes, de travail dans leur ordre puis « Gagnée » et « Perdue ».
    def self.stages(active_only : Bool = false) : Array(Stage)
      rows = Stage.all.to_a
      rows.select!(&.active) if active_only
      rows.sort_by! { |stage| {stage_rank(stage.kind.to_s), (stage.position || 0).to_i64, stage.id || 0_i64} }
    end

    def self.stage_rank(kind : String) : Int32
      case kind
      when "open" then 0
      when "won"  then 1
      else             2
      end
    end

    def self.closing_stage(kind : String) : Stage
      Stage.filter(kind: kind).first || raise "crm : étape #{kind} absente (migration 0001)"
    end

    def self.first_open_stage : Stage
      stages(active_only: true).find(&.kind.==("open")) || closing_stage("won")
    end

    def self.stage_views : Hash(Int64, Api::StageView)
      Stage.all.to_a.to_h { |stage| {stage.id!.to_i64, stage_view(stage)} }
    end

    # --- Vues --------------------------------------------------------------------

    def self.stage_view(stage : Stage) : Api::StageView
      Api::StageView.new(stage.id!.to_i64, stage.code.to_s, stage.name.to_s, (stage.position || 0).to_i32, (stage.probability || 0).to_i32,
        stage.kind.to_s, stage.active || false)
    end

    def self.choice_view(row : LossReason | Source) : Api::ChoiceView
      scope = row.is_a?(LossReason) ? "crm.loss_reasons" : "crm.sources"
      Api::ChoiceView.new(row.id!.to_i64, row.code.to_s, row.name.to_s, (row.position || 0).to_i32, row.active || false, scope)
    end

    def self.organization_view(row : Organization) : Api::OrganizationView
      Api::OrganizationView.new(
        id: row.id!.to_i64, name: row.name.to_s, nature: row.nature.to_s, siren: row.siren.to_s,
        vat_number: row.vat_number.to_s, email: row.email.to_s, phone: row.phone.to_s, website: row.website.to_s,
        line1: row.line1.to_s, postcode: row.postcode.to_s, city: row.city.to_s, country_code: row.country_code.to_s,
        card_id: row.card_id.try(&.to_i64), source_id: row.source_id.try(&.to_i64), owner_id: row.owner_id.try(&.to_i64),
        notes: row.notes.to_s, created_at: row.created_at || Time.utc, updated_at: row.updated_at || Time.utc,
      )
    end

    def self.contact_views(rows : Array(Contact)) : Array(Api::ContactView)
      names = organization_names(rows.compact_map(&.organization_id.try(&.to_i64)))
      rows.map do |row|
        Api::ContactView.new(
          id: row.id!.to_i64, organization_id: row.organization_id.try(&.to_i64),
          organization_name: row.organization_id.try { |id| names[id.to_i64]? }, civility: row.civility.to_s,
          first_name: row.first_name.to_s, last_name: row.last_name.to_s, job_title: row.job_title.to_s,
          email: row.email.to_s, phone: row.phone.to_s, mobile: row.mobile.to_s, source_id: row.source_id.try(&.to_i64),
          legal_basis: row.legal_basis.to_s, legal_basis_on: row.legal_basis_on, opposed_at: row.opposed_at,
          opposition_note: row.opposition_note.to_s, notes: row.notes.to_s, created_at: row.created_at || Time.utc,
          updated_at: row.updated_at || Time.utc,
        )
      end
    end

    def self.contact_view(row : Contact) : Api::ContactView
      contact_views([row]).first
    end

    # Vues d'opportunités, avec le nom de l'organisation et du contact, et
    # la prochaine activité à faire (ADR-009 D4), lus en trois requêtes.
    def self.opportunity_views(rows : Array(Opportunity)) : Array(Api::OpportunityView)
      stages = stage_views
      organizations = Organization.filter(id__in: rows.map(&.organization_id!.to_i64).uniq!).to_a.to_h { |row| {row.id!.to_i64, row} }
      contacts = contact_names(rows.compact_map(&.contact_id.try(&.to_i64)))
      next_steps = next_activities(rows.map(&.id!.to_i64))
      rows.map do |row|
        organization = organizations[row.organization_id!.to_i64]?
        Api::OpportunityView.new(
          id: row.id!.to_i64, title: row.title.to_s, organization_id: row.organization_id!.to_i64,
          organization_name: organization.try(&.name.to_s) || "—", organization_customer: !organization.try(&.card_id).nil?,
          contact_id: row.contact_id.try(&.to_i64), contact_name: row.contact_id.try { |id| contacts[id.to_i64]? },
          amount: row.amount || BigDecimal.new(0), probability: (row.probability || 0).to_i32,
          expected_close_on: row.expected_close_on, owner_id: row.owner_id.try(&.to_i64),
          stage: stages[row.stage_id!.to_i64], source_id: row.source_id.try(&.to_i64),
          loss_reason_id: row.loss_reason_id.try(&.to_i64), loss_note: row.loss_note.to_s, closed_at: row.closed_at,
          next_activity_on: next_steps[row.id!.to_i64]?, created_at: row.created_at || Time.utc,
          updated_at: row.updated_at || Time.utc,
        )
      end
    end

    def self.opportunity_view(row : Opportunity) : Api::OpportunityView
      opportunity_views([row]).first
    end

    def self.activity_views(rows : Array(Activity)) : Array(Api::ActivityView)
      organizations = organization_names(rows.compact_map(&.organization_id.try(&.to_i64)))
      contacts = contact_names(rows.compact_map(&.contact_id.try(&.to_i64)))
      titles = Opportunity.filter(id__in: rows.compact_map(&.opportunity_id.try(&.to_i64)).uniq!).to_a
        .to_h { |row| {row.id!.to_i64, row.title.to_s} }
      rows.map do |row|
        Api::ActivityView.new(
          id: row.id!.to_i64, kind: row.kind.to_s, subject: row.subject.to_s, due_on: row.due_on || today,
          starts_at: row.starts_at, duration_minutes: row.duration_minutes.try(&.to_i32), owner_id: row.owner_id.try(&.to_i64),
          report: row.report.to_s, done: row.done || false, done_at: row.done_at,
          organization_id: row.organization_id.try(&.to_i64), organization_name: row.organization_id.try { |id| organizations[id.to_i64]? },
          contact_id: row.contact_id.try(&.to_i64), contact_name: row.contact_id.try { |id| contacts[id.to_i64]? },
          opportunity_id: row.opportunity_id.try(&.to_i64), opportunity_title: row.opportunity_id.try { |id| titles[id.to_i64]? },
          created_at: row.created_at || Time.utc,
        )
      end
    end

    def self.activity_view(row : Activity) : Api::ActivityView
      activity_views([row]).first
    end

    # --- Outils ------------------------------------------------------------------

    def self.organization_names(ids : Array(Int64)) : Hash(Int64, String)
      return {} of Int64 => String if ids.empty?
      Organization.filter(id__in: ids.uniq).to_a.to_h { |row| {row.id!.to_i64, row.name.to_s} }
    end

    def self.contact_names(ids : Array(Int64)) : Hash(Int64, String)
      return {} of Int64 => String if ids.empty?
      Contact.filter(id__in: ids.uniq).to_a.to_h { |row| {row.id!.to_i64, "#{row.first_name} #{row.last_name}".strip} }
    end

    # Échéance de la prochaine activité à faire, aujourd'hui ou plus tard,
    # par opportunité.
    def self.next_activities(ids : Array(Int64)) : Hash(Int64, Time)
      found = {} of Int64 => Time
      return found if ids.empty?
      Activity.filter(opportunity_id__in: ids, done: false, due_on__gte: today).order(:due_on).each do |row|
        opportunity = row.opportunity_id.try(&.to_i64) || next
        due = row.due_on
        found[opportunity] = due if due && !found.has_key?(opportunity)
      end
      found
    end

    # Utilisateurs du dossier par identifiant (responsables), lus par le
    # contrat du cœur avec l'acteur système (D-CRM-006).
    def self.users : Hash(Int64, Partiduo::Api::Auth::UserView)
      Partiduo::Api::Auth.users(Partiduo::Api::Actor.system).to_h { |user| {user.id, user} }
    end

    def self.user_name(user : Partiduo::Api::Auth::UserView) : String
      user.full_name.presence || user.email
    end
  end
end
