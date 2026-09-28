# SPDX-License-Identifier: AGPL-3.0-or-later

module Crm
  # Contrat public de l'extension CRM (ADR-009), sur le modèle de
  # `Partiduo::Api` (DECISIONS C2 du cœur) : acteur en premier argument,
  # contrôle d'accès en première ligne (extension active et permission),
  # objets de vue immuables, toute écriture par une commande qui rend un
  # `Result` avec ses erreurs par champ, dans une transaction. L'interface
  # de l'extension (`ui/bulma/`) ne voit que ce module et `Partiduo::Api`.
  #
  # Référence : `doc/api/crm.adoc`.
  module Api
    alias Actor = Partiduo::Api::Actor
    alias Guard = Partiduo::Api::Guard
    alias Result = Partiduo::Api::Result
    alias FieldError = Partiduo::Api::FieldError
    alias Transaction = Partiduo::Api::Transaction
    alias Inv = Partiduo::Api::Invoicing

    MODULE_CODE = Crm::CODE
    READ        = "crm.read"
    WRITE       = "crm.write"
    ADMIN       = "crm.admin"

    # Permissions du cœur exigées en plus (ADR-009 D7, D-CRM-004).
    QUOTE_PERMISSION    = Inv::WRITE
    CUSTOMER_PERMISSION = "cards.card.write"

    MAX_LIMIT = 1000

    # --- Organisations -----------------------------------------------------------

    def self.organizations(actor : Actor, query : OrganizationQuery = OrganizationQuery.new) : Array(OrganizationView)
      authorize!(actor, READ)
      rows = Organization.all
      case query.status
      when "prospect" then rows = rows.filter(card_id__isnull: true)
      when "customer" then rows = rows.filter(card_id__isnull: false)
      end
      query.owner_id.try { |id| rows = rows.filter(owner_id: id) }
      if text = query.search.try(&.strip).presence
        rows = rows.filter { q(name__icontains: text) | q(siren__icontains: text) | q(email__icontains: text) | q(city__icontains: text) }
      end
      page(rows.order(:name, :id), query.offset, query.limit).map { |row| Records.organization_view(row) }
    end

    def self.organization(actor : Actor, id : Int64) : OrganizationView
      authorize!(actor, READ)
      Records.organization_view(Records.organization!(id))
    end

    # Organisation rattachée à une fiche du cœur, ou `nil`.
    def self.organization_for_card(actor : Actor, card_id : Int64) : OrganizationView?
      authorize!(actor, READ)
      Organization.filter(card_id: card_id).first.try { |row| Records.organization_view(row) }
    end

    def self.check_organization(actor : Actor, input : OrganizationInput) : Result(Nil)
      authorize!(actor, WRITE)
      errors = [] of FieldError
      Rules.organization(input, errors)
      errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
    end

    # Nouvelle organisation, prospect (ADR-009 D2). Responsable par défaut :
    # l'acteur.
    def self.create_organization(actor : Actor, input : OrganizationInput) : Result(OrganizationView)
      authorize!(actor, WRITE)
      input = input.copy_with(owner_id: input.owner_id || actor.user_id)
      errors = [] of FieldError
      values = Rules.organization(input, errors)
      return Result(OrganizationView).failure(errors) unless errors.empty?
      Transaction.run do
        row = Rules.apply_organization(Organization.new(created_by_id: actor.user_id), values)
        row.save!
        Result(OrganizationView).success(Records.organization_view(row))
      end
    end

    # Modifie une organisation. Celle d'un client garde sa fiche : les
    # coordonnées de la fiche se modifient dans le référentiel du cœur, qui
    # les renvoie ici par `card.saved`.
    def self.update_organization(actor : Actor, id : Int64, input : OrganizationInput) : Result(OrganizationView)
      authorize!(actor, WRITE)
      errors = [] of FieldError
      values = Rules.organization(input, errors)
      return Result(OrganizationView).failure(errors) unless errors.empty?
      Transaction.run do
        row = Rules.apply_organization(Records.organization!(id, lock: true), values)
        row.save!
        Result(OrganizationView).success(Records.organization_view(row))
      end
    end

    # « Devenir client » (ADR-009 D2) : action explicite qui crée la fiche
    # client du cœur par `Partiduo::Api::Cards` et y rattache
    # l'organisation. Exige aussi `cards.card.write`.
    def self.become_customer(actor : Actor, id : Int64, input : CustomerInput = CustomerInput.new) : Result(OrganizationView)
      authorize!(actor, WRITE)
      Guard.authorize!(actor, CUSTOMER_PERMISSION, module_code: "CARDS")
      Transaction.run do
        row = Records.organization!(id, lock: true)
        errors = Conversion.become_customer!(actor, row, input)
        next Result(OrganizationView).failure(errors) unless errors.empty?
        Result(OrganizationView).success(Records.organization_view(Records.organization!(id)))
      end
    end

    # Supprime un prospect sans contact, opportunité ni activité
    # (`crm.admin`) ; une organisation cliente ou suivie se garde.
    def self.delete_organization(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, ADMIN)
      Transaction.run do
        row = Records.organization!(id, lock: true)
        in_use = row.card_id || Contact.filter(organization_id: id).exists? || Opportunity.filter(organization_id: id).exists? ||
                 Activity.filter(organization_id: id).exists?
        next Result(Nil).failure(Records.error(FieldError::BASE, "organization.in_use")) if in_use
        row.delete
        Result(Nil).success(nil)
      end
    end

    # --- Contacts ------------------------------------------------------------------

    def self.contacts(actor : Actor, query : ContactQuery = ContactQuery.new) : Array(ContactView)
      authorize!(actor, READ)
      rows = Contact.all
      query.organization_id.try { |id| rows = rows.filter(organization_id: id) }
      case query.opposed
      when false then rows = rows.filter(opposed_at__isnull: true)
      when true  then rows = rows.filter(opposed_at__isnull: false)
      end
      if text = query.search.try(&.strip).presence
        rows = rows.filter do
          q(last_name__icontains: text) | q(first_name__icontains: text) | q(email__icontains: text) | q(job_title__icontains: text)
        end
      end
      Records.contact_views(page(rows.order(:last_name, :first_name, :id), query.offset, query.limit))
    end

    def self.contact(actor : Actor, id : Int64) : ContactView
      authorize!(actor, READ)
      Records.contact_view(Records.contact!(id))
    end

    def self.check_contact(actor : Actor, input : ContactInput) : Result(Nil)
      authorize!(actor, WRITE)
      errors = [] of FieldError
      Rules.contact(input, errors)
      errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
    end

    def self.create_contact(actor : Actor, input : ContactInput) : Result(ContactView)
      authorize!(actor, WRITE)
      errors = [] of FieldError
      values = Rules.contact(input, errors)
      return Result(ContactView).failure(errors) unless errors.empty?
      Transaction.run do
        row = Rules.apply_contact(Contact.new, values)
        row.save!
        Result(ContactView).success(Records.contact_view(row))
      end
    end

    # Modifie un contact ; l'opposition se déclare à part (`record_opposition`).
    def self.update_contact(actor : Actor, id : Int64, input : ContactInput) : Result(ContactView)
      authorize!(actor, WRITE)
      errors = [] of FieldError
      values = Rules.contact(input, errors)
      return Result(ContactView).failure(errors) unless errors.empty?
      Transaction.run do
        row = Rules.apply_contact(Records.contact!(id, lock: true), values)
        row.save!
        Result(ContactView).success(Records.contact_view(row))
      end
    end

    # Opposition du contact à la prospection (RGPD, ADR-009 D2), datée :
    # il n'apparaît plus dans les listes d'actions commerciales et ne peut
    # plus être choisi pour une opportunité ou une activité.
    def self.record_opposition(actor : Actor, id : Int64, note : String = "") : Result(ContactView)
      authorize!(actor, WRITE)
      if note.strip.size > 2000
        return Result(ContactView).failure(Records.error("opposition_note", "contact.opposition_note.too_long", {"max" => "2000"}))
      end
      Transaction.run do
        row = Records.contact!(id, lock: true)
        next Result(ContactView).failure(Records.error(FieldError::BASE, "contact.already_opposed")) if row.opposed_at
        row.opposed_at = Time.utc
        row.opposition_note = note.strip
        row.save!
        Result(ContactView).success(Records.contact_view(row))
      end
    end

    # Retire l'opposition (le contact l'a demandé) ; la date est effacée,
    # la base légale doit être de nouveau établie (`crm.admin`).
    def self.withdraw_opposition(actor : Actor, id : Int64) : Result(ContactView)
      authorize!(actor, ADMIN)
      Transaction.run do
        row = Records.contact!(id, lock: true)
        next Result(ContactView).failure(Records.error(FieldError::BASE, "contact.not_opposed")) unless row.opposed_at
        row.opposed_at = nil
        row.opposition_note = ""
        row.legal_basis = ""
        row.legal_basis_on = nil
        row.save!
        Result(ContactView).success(Records.contact_view(row))
      end
    end

    # Le contact est-il lié à un devis (contact principal d'une opportunité
    # qui porte un devis) ? Il ne peut alors pas être effacé.
    def self.contact_quoted?(actor : Actor, id : Int64) : Bool
      authorize!(actor, READ)
      quoted_contact?(id)
    end

    # Effacement RGPD d'un contact (`crm.admin`, ADR-009 D2), possible tant
    # qu'il n'est lié à aucun devis : ses activités propres (sans
    # organisation ni opportunité) sont effacées avec lui, les autres et
    # les opportunités le perdent comme contact.
    def self.erase_contact(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, ADMIN)
      Transaction.run do
        row = Records.contact!(id, lock: true)
        next Result(Nil).failure(Records.error(FieldError::BASE, "contact.quoted")) if quoted_contact?(id)
        Activity.filter(contact_id: id, organization_id__isnull: true, opportunity_id__isnull: true).delete
        Activity.filter(contact_id: id).update(contact_id: nil)
        Opportunity.filter(contact_id: id).update(contact_id: nil)
        row.delete
        Result(Nil).success(nil)
      end
    end

    # --- Opportunités ---------------------------------------------------------------

    def self.opportunities(actor : Actor, query : OpportunityQuery = OpportunityQuery.new) : Array(OpportunityView)
      authorize!(actor, READ)
      rows = Opportunity.all
      query.stage_id.try { |id| rows = rows.filter(stage_id: id) }
      query.owner_id.try { |id| rows = rows.filter(owner_id: id) }
      query.organization_id.try { |id| rows = rows.filter(organization_id: id) }
      query.contact_id.try { |id| rows = rows.filter(contact_id: id) }
      if status = query.status
        rows = rows.filter(stage_id__in: Stage.filter(kind: status).to_a.map(&.id!.to_i64))
      end
      if text = query.search.try(&.strip).presence
        organizations = Organization.filter(name__icontains: text).to_a.map(&.id!.to_i64)
        rows = rows.filter { q(title__icontains: text) | q(organization_id__in: organizations) }
      end
      views = Records.opportunity_views(rows.order(:expected_close_on, :id).to_a)
      views.select!(&.no_next_step?) if query.no_next_step
      offset = Math.max(query.offset, 0)
      views[offset, query.limit.clamp(1, MAX_LIMIT)]? || [] of OpportunityView
    end

    def self.opportunity(actor : Actor, id : Int64) : OpportunityView
      authorize!(actor, READ)
      Records.opportunity_view(Records.opportunity!(id))
    end

    def self.check_opportunity(actor : Actor, input : OpportunityInput, id : Int64? = nil) : Result(Nil)
      authorize!(actor, WRITE)
      errors = [] of FieldError
      Rules.opportunity(input, errors, id.try { |value| Records.opportunity!(value) })
      errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
    end

    # Nouvelle opportunité, à la première étape de travail (ou à `stage_id`,
    # étape de travail active), probabilité de l'étape si elle n'est pas
    # donnée, responsable par défaut : l'acteur. La création est historisée.
    def self.create_opportunity(actor : Actor, input : OpportunityInput) : Result(OpportunityView)
      authorize!(actor, WRITE)
      input = input.copy_with(owner_id: input.owner_id || actor.user_id)
      errors = [] of FieldError
      values = Rules.opportunity(input, errors)
      return Result(OpportunityView).failure(errors) unless errors.empty?
      Transaction.run do
        row = Rules.apply_opportunity(Opportunity.new(created_by_id: actor.user_id), values)
        row.save!
        Pipeline.record!(row.id!.to_i64, nil, row.stage_id!.to_i64, actor.user_id, "created")
        Result(OpportunityView).success(Records.opportunity_view(row))
      end
    end

    # Modifie une opportunité, sans changer son étape (`move_opportunity`).
    def self.update_opportunity(actor : Actor, id : Int64, input : OpportunityInput) : Result(OpportunityView)
      authorize!(actor, WRITE)
      Transaction.run do
        row = Records.opportunity!(id, lock: true)
        errors = [] of FieldError
        values = Rules.opportunity(input, errors, row)
        next Result(OpportunityView).failure(errors) unless errors.empty?
        Rules.apply_opportunity(row, values).save!
        Result(OpportunityView).success(Records.opportunity_view(row))
      end
    end

    # Change l'étape d'une opportunité (pipeline, ADR-009 D3) : probabilité
    # de l'étape, clôture datée, motif obligatoire pour « Perdue » ;
    # historisé (qui, quand, d'où, vers où).
    def self.move_opportunity(actor : Actor, id : Int64, input : MoveInput) : Result(OpportunityView)
      authorize!(actor, WRITE)
      Transaction.run do
        row = Records.opportunity!(id, lock: true)
        stage = Stage.filter(id: input.stage_id).first
        errors = Pipeline.errors(row, stage, input)
        next Result(OpportunityView).failure(errors) unless errors.empty? && stage
        Pipeline.move!(row, stage, actor.user_id, loss_reason_id: input.loss_reason_id, loss_note: input.loss_note)
        Result(OpportunityView).success(Records.opportunity_view(row))
      end
    end

    # Historique des étapes, du plus ancien au plus récent.
    def self.stage_history(actor : Actor, id : Int64) : Array(StageChangeView)
      authorize!(actor, READ)
      Records.opportunity!(id)
      stages = Records.stage_views
      StageChange.filter(opportunity_id: id).order(:id).map do |row|
        StageChangeView.new(row.id!.to_i64, row.from_stage_id.try { |stage| stages[stage.to_i64]? }, stages[row.to_stage_id!.to_i64],
          row.user_id.try(&.to_i64), row.cause.to_s, row.created_at || Time.utc)
      end
    end

    # Pipeline en colonnes par étape (ADR-009 D3) : étapes de travail
    # actives, puis « Gagnée » et « Perdue » (opportunités closes depuis
    # `closed_since`, défaut : 30 jours).
    def self.pipeline(actor : Actor, owner_id : Int64? = nil, closed_since : Time? = nil) : PipelineView
      authorize!(actor, READ)
      since = closed_since || (Records.today - 30.days)
      stages = Records.stages(active_only: true)
      rows = Opportunity.filter(stage_id__in: stages.map(&.id!.to_i64))
      rows = rows.filter(owner_id: owner_id) if owner_id
      views = Records.opportunity_views(rows.order(:expected_close_on, :id).to_a)
      columns = stages.map do |stage|
        listed = views.select(&.stage_id.==(stage.id))
        listed.select! { |view| (view.closed_at || Time.utc) >= since } unless stage.kind == "open"
        ColumnView.new(Records.stage_view(stage), listed)
      end
      PipelineView.new(columns)
    end

    # « Créer un devis » (ADR-009 D5) : si l'organisation est un prospect,
    # elle devient d'abord cliente ; un devis brouillon est créé par
    # `Partiduo::Api::Invoicing.create_document` et lié à l'opportunité, qui
    # passe à « Proposition » si elle était avant. Exige aussi
    # `invoicing.invoice.write` (et `cards.card.write` pour un prospect).
    # Une opportunité peut porter plusieurs devis (versions successives).
    def self.create_quote(actor : Actor, id : Int64) : Result(Inv::DocumentView)
      authorize!(actor, WRITE)
      Guard.authorize!(actor, QUOTE_PERMISSION, module_code: Inv::MODULE)
      Transaction.run do
        row = Records.opportunity!(id, lock: true)
        organization = Records.organization!(row.organization_id!.to_i64)
        if organization.card_id.nil? && !actor.can?(CUSTOMER_PERMISSION)
          raise Partiduo::Api::Forbidden.new(CUSTOMER_PERMISSION)
        end
        case outcome = Conversion.create_quote!(actor, row)
        in Inv::DocumentView then Result(Inv::DocumentView).success(outcome)
        in Array(FieldError) then Result(Inv::DocumentView).failure(outcome)
        end
      end
    end

    # Devis et factures rattachés à une opportunité, relus dans la
    # Facturation (sans droit de lecture : numéro et état inconnus).
    def self.documents(actor : Actor, id : Int64) : Array(DocumentView)
      authorize!(actor, READ)
      Records.opportunity!(id)
      readable = actor.can?(Inv::READ) && Partiduo::Modules.active?(Inv::MODULE)
      DocumentLink.filter(opportunity_id: id).order(:id).map do |link|
        document = readable ? read_document(actor, link.document_id!.to_i64) : nil
        DocumentView.new(id: link.id!.to_i64, document_id: link.document_id!.to_i64,
          kind: document.try(&.kind) || link.kind.to_s, number: document.try(&.number),
          status: document.try(&.effective_status), total_net: document.try(&.totals.total_net),
          issue_date: document.try(&.issue_date), readable: !document.nil?, created_at: link.created_at || Time.utc)
      end
    end

    # --- Activités -------------------------------------------------------------------

    def self.activities(actor : Actor, query : ActivityQuery = ActivityQuery.new) : Array(ActivityView)
      authorize!(actor, READ)
      rows = Activity.all
      query.owner_id.try { |id| rows = rows.filter(owner_id: id) }
      query.organization_id.try { |id| rows = rows.filter(organization_id: id) }
      query.contact_id.try { |id| rows = rows.filter(contact_id: id) }
      query.opportunity_id.try { |id| rows = rows.filter(opportunity_id: id) }
      query.done.try { |done| rows = rows.filter(done: done) }
      Records.activity_views(rows.order("-due_on", "-id")[0...query.limit.clamp(1, MAX_LIMIT)].to_a)
    end

    def self.activity(actor : Actor, id : Int64) : ActivityView
      authorize!(actor, READ)
      Records.activity_view(Records.activity!(id))
    end

    # « Mes activités » (ADR-009 D4) : activités à faire du responsable
    # (défaut : l'acteur), en retard, aujourd'hui, à venir. Celles d'un
    # contact opposé à la prospection n'y figurent plus (ADR-009 D2).
    def self.agenda(actor : Actor, owner_id : Int64? = nil) : AgendaView
      authorize!(actor, READ)
      owner = owner_id || actor.user_id
      rows = Activity.filter(done: false)
      rows = owner ? rows.filter(owner_id: owner) : rows.filter(owner_id__isnull: true)
      opposed = opposed_contact_ids
      views = Records.activity_views(rows.order(:due_on, :id).to_a.reject { |row| row.contact_id.try { |id| opposed.includes?(id.to_i64) } })
      today = Records.today
      AgendaView.new(views.select(&.due_on.<(today)), views.select(&.due_on.==(today)), views.select(&.due_on.>(today)))
    end

    def self.check_activity(actor : Actor, input : ActivityInput) : Result(Nil)
      authorize!(actor, WRITE)
      errors = [] of FieldError
      Rules.activity(input, errors)
      errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
    end

    # Nouvelle activité, responsable par défaut : l'acteur ; une note est
    # faite dès sa saisie.
    def self.create_activity(actor : Actor, input : ActivityInput) : Result(ActivityView)
      authorize!(actor, WRITE)
      input = input.copy_with(owner_id: input.owner_id || actor.user_id)
      errors = [] of FieldError
      values = Rules.activity(input, errors)
      return Result(ActivityView).failure(errors) unless errors.empty?
      Transaction.run do
        row = Rules.apply_activity(Activity.new(created_by_id: actor.user_id), values)
        row.save!
        Result(ActivityView).success(Records.activity_view(row))
      end
    end

    def self.update_activity(actor : Actor, id : Int64, input : ActivityInput) : Result(ActivityView)
      authorize!(actor, WRITE)
      errors = [] of FieldError
      values = Rules.activity(input, errors)
      return Result(ActivityView).failure(errors) unless errors.empty?
      Transaction.run do
        row = Rules.apply_activity(Records.activity!(id, lock: true), values)
        row.save!
        Result(ActivityView).success(Records.activity_view(row))
      end
    end

    # Marque une activité faite (`done`) ou de nouveau à faire, avec son
    # compte rendu s'il est donné.
    def self.complete_activity(actor : Actor, id : Int64, done : Bool = true, report : String? = nil) : Result(ActivityView)
      authorize!(actor, WRITE)
      if report && report.strip.size > 20_000
        return Result(ActivityView).failure(Records.error("report", "activity.report.too_long", {"max" => "20000"}))
      end
      Transaction.run do
        row = Records.activity!(id, lock: true)
        row.done = done
        row.done_at = done ? Time.utc : nil
        report.try { |text| row.report = text.strip }
        row.save!
        Result(ActivityView).success(Records.activity_view(row))
      end
    end

    def self.delete_activity(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, WRITE)
      Transaction.run do
        Records.activity!(id, lock: true).delete
        Result(Nil).success(nil)
      end
    end

    # --- Paramétrage -------------------------------------------------------------------

    # Étapes, de travail dans leur ordre puis « Gagnée » et « Perdue ».
    def self.stages(actor : Actor, active_only : Bool = false) : Array(StageView)
      authorize!(actor, READ)
      Records.stages(active_only).map { |stage| Records.stage_view(stage) }
    end

    def self.loss_reasons(actor : Actor, active_only : Bool = false) : Array(ChoiceView)
      authorize!(actor, READ)
      choices(LossReason, active_only)
    end

    def self.sources(actor : Actor, active_only : Bool = false) : Array(ChoiceView)
      authorize!(actor, READ)
      choices(Source, active_only)
    end

    # Utilisateurs du dossier, responsables possibles (D-CRM-006).
    def self.owners(actor : Actor) : Array(OwnerView)
      authorize!(actor, READ)
      Records.users.values.select(&.active).map { |user| OwnerView.new(user.id, Records.user_name(user)) }.sort_by!(&.name)
    end

    # Nouvelle étape de travail (`crm.admin`) ; « Gagnée » et « Perdue »
    # sont fixes.
    def self.create_stage(actor : Actor, input : StageInput) : Result(StageView)
      authorize!(actor, ADMIN)
      errors = stage_errors(input, nil)
      return Result(StageView).failure(errors) unless errors.empty?
      Transaction.run do
        row = Stage.create!(code: "", name: input.name.strip, position: input.position, probability: input.probability,
          kind: "open", active: input.active)
        Result(StageView).success(Records.stage_view(row))
      end
    end

    # Modifie une étape : nom, ordre, probabilité par défaut (étape de
    # travail), activité. Une étape qui porte des opportunités ouvertes ne se
    # désactive pas ; « Gagnée » et « Perdue » restent actives.
    def self.update_stage(actor : Actor, id : Int64, input : StageInput) : Result(StageView)
      authorize!(actor, ADMIN)
      Transaction.run do
        row = Records.stage!(id)
        errors = stage_errors(input, row)
        next Result(StageView).failure(errors) unless errors.empty?
        row.name = input.name.strip
        row.position = input.position
        if row.kind == "open"
          row.probability = input.probability
          row.active = input.active
        end
        row.save!
        Result(StageView).success(Records.stage_view(row))
      end
    end

    def self.create_loss_reason(actor : Actor, input : ChoiceInput) : Result(ChoiceView)
      create_choice(actor, LossReason, input, "loss_reason")
    end

    def self.update_loss_reason(actor : Actor, id : Int64, input : ChoiceInput) : Result(ChoiceView)
      update_choice(actor, LossReason, id, input, "loss_reason")
    end

    def self.create_source(actor : Actor, input : ChoiceInput) : Result(ChoiceView)
      create_choice(actor, Source, input, "source")
    end

    def self.update_source(actor : Actor, id : Int64, input : ChoiceInput) : Result(ChoiceView)
      update_choice(actor, Source, id, input, "source")
    end

    # --- Tableau de bord ---------------------------------------------------------------

    # Tableau de bord commercial (ADR-009 D6) sur la période `from`..`to`
    # (défaut : l'année civile en cours).
    def self.dashboard(actor : Actor, from : Time? = nil, to : Time? = nil) : DashboardView
      authorize!(actor, READ)
      today = Records.today
      Board.build(actor, from || Time.utc(today.year, 1, 1), to || Time.utc(today.year, 12, 31))
    end

    # Tuile « Commercial » du tableau de bord du dossier : `nil` si
    # l'extension est inactive ou l'acteur sans droit de lecture.
    def self.tile(actor : Actor) : TileView?
      return unless Partiduo::Modules.active?(MODULE_CODE) && actor.can?(READ)
      open_ids = Stage.filter(kind: "open").to_a.map(&.id!.to_i64)
      views = Records.opportunity_views(Opportunity.filter(stage_id__in: open_ids).to_a)
      TileView.new(views.sum(BigDecimal.new(0), &.weighted_amount), views.size.to_i64, Board.late_activities)
    end

    # Compteur du menu « Mes activités » : activités à faire de l'acteur en
    # retard ou du jour ; `nil` si l'extension est inactive ou sans droit.
    def self.due_count(actor : Actor) : Int64?
      return unless Partiduo::Modules.active?(MODULE_CODE) && actor.can?(READ)
      owner = actor.user_id || return
      Activity.filter(done: false, owner_id: owner, due_on__lte: Records.today).count.to_i64
    end

    # --- Import et export (ADR-009 D8) -----------------------------------------------

    # Aperçu d'un import CSV : correspondance des colonnes, lignes, erreurs
    # et doublons (SIREN, courriel, nom), sans rien enregistrer.
    def self.preview_import(actor : Actor, input : ImportInput) : Result(ImportPreviewView)
      authorize!(actor, WRITE)
      case outcome = Importer.preview(input)
      in ImportPreviewView then Result(ImportPreviewView).success(outcome)
      in Array(FieldError) then Result(ImportPreviewView).failure(outcome)
      end
    end

    # Importe les lignes sans erreur ni doublon ; les autres sont rendues
    # dans le bilan.
    def self.import(actor : Actor, input : ImportInput) : Result(ImportReportView)
      authorize!(actor, WRITE)
      preview = preview_import(actor, input)
      return Result(ImportReportView).failure(preview.errors) if preview.failure?
      Transaction.run do
        Result(ImportReportView).success(Importer.import!(actor, preview.value!, input))
      end
    end

    # Export CSV des contacts pour une action commerciale : contacts non
    # opposés seulement (ADR-009 D2), séparateur `;`, en-têtes traduits.
    def self.export_contacts(actor : Actor, query : ContactQuery = ContactQuery.new) : String
      authorize!(actor, READ)
      rows = contacts(actor, query.copy_with(opposed: false, limit: MAX_LIMIT))
      fields = %w[contact_civility contact_first_name contact_last_name contact_job_title contact_email contact_phone
        contact_mobile organization_name legal_basis]
      "\uFEFF" + CSV.build(separator: ';') do |csv|
        csv.row(fields.map { |field| I18n.t("crm.import.fields.#{field}") })
        rows.each do |row|
          csv.row([row.civility_key.try { |key| I18n.t(key) } || "", row.first_name, row.last_name, row.job_title, row.email,
                   row.phone, row.mobile, row.organization_name || "", row.legal_basis_key.try { |key| I18n.t(key) } || ""])
        end
      end
    end

    # --- Outils ------------------------------------------------------------------------

    private def self.authorize!(actor : Actor, permission : String) : Nil
      Guard.authorize!(actor, permission, module_code: MODULE_CODE)
    end

    private def self.page(rows, offset : Int32, limit : Int32)
      start = Math.max(offset, 0)
      rows[start...(start + limit.clamp(1, MAX_LIMIT))].to_a
    end

    private def self.read_document(actor : Actor, id : Int64) : Inv::DocumentView?
      Inv.document(actor, id)
    rescue Partiduo::Api::NotFound | Partiduo::Api::AccessDenied
      nil
    end

    private def self.quoted_contact?(id : Int64) : Bool
      ids = Opportunity.filter(contact_id: id).to_a.map(&.id!.to_i64)
      !ids.empty? && DocumentLink.filter(opportunity_id__in: ids, kind: "quote").exists?
    end

    private def self.opposed_contact_ids : Set(Int64)
      Contact.filter(opposed_at__isnull: false).to_a.map(&.id!.to_i64).to_set
    end

    private def self.choices(model, active_only : Bool) : Array(ChoiceView)
      rows = model.all.order(:position, :id).to_a
      rows.select!(&.active) if active_only
      rows.map { |row| Records.choice_view(row) }
    end

    private def self.stage_errors(input : StageInput, row : Stage?) : Array(FieldError)
      errors = [] of FieldError
      name = input.name.strip
      if name.empty? && (row.nil? || row.code.to_s.empty?)
        errors << Records.error("name", "stage.name.blank")
      elsif name.size > 100
        errors << Records.error("name", "stage.name.too_long", {"max" => "100"})
      end
      working = row.nil? || row.kind == "open"
      errors << Records.error("probability", "stage.probability.range") if working && !(0..100).includes?(input.probability)
      errors << Records.error("position", "stage.position.range") if working && !(0..999).includes?(input.position)
      row.try { |stage| deactivation_errors(stage, input, errors) }
      errors
    end

    # Une étape de travail se désactive sans opportunité et s'il en reste
    # une autre active.
    private def self.deactivation_errors(row : Stage, input : StageInput, errors : Array(FieldError)) : Nil
      return if row.kind != "open" || input.active || !row.active
      if Opportunity.filter(stage_id: row.id).exists?
        errors << Records.error("active", "stage.active.in_use")
      elsif Stage.filter(kind: "open", active: true).exclude(id: row.id).count.zero?
        errors << Records.error("active", "stage.active.last")
      end
    end

    private def self.create_choice(actor : Actor, model, input : ChoiceInput, object : String) : Result(ChoiceView)
      authorize!(actor, ADMIN)
      errors = choice_errors(input, nil, object)
      return Result(ChoiceView).failure(errors) unless errors.empty?
      Transaction.run do
        row = model.create!(code: "", name: input.name.strip, position: input.position, active: input.active)
        Result(ChoiceView).success(Records.choice_view(row))
      end
    end

    private def self.update_choice(actor : Actor, model, id : Int64, input : ChoiceInput, object : String) : Result(ChoiceView)
      authorize!(actor, ADMIN)
      Transaction.run do
        row = model.filter(id: id).first || raise Partiduo::Api::NotFound.new("crm_#{object}", id)
        errors = choice_errors(input, row.code.to_s, object)
        next Result(ChoiceView).failure(errors) unless errors.empty?
        row.name = input.name.strip
        row.position = input.position
        row.active = input.active
        row.save!
        Result(ChoiceView).success(Records.choice_view(row))
      end
    end

    private def self.choice_errors(input : ChoiceInput, code : String?, object : String) : Array(FieldError)
      errors = [] of FieldError
      name = input.name.strip
      if name.empty? && code.to_s.empty?
        errors << Records.error("name", "#{object}.name.blank")
      elsif name.size > 100
        errors << Records.error("name", "#{object}.name.too_long", {"max" => "100"})
      end
      errors << Records.error("position", "#{object}.position.range") unless (0..999).includes?(input.position)
      errors
    end
  end
end
