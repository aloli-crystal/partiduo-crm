# SPDX-License-Identifier: AGPL-3.0-or-later

module Crm
  module Api
    # Natures d'une organisation : celles d'un client du cœur (ADR-004 D9).
    # Libellé : `crm.natures.<code>`.
    NATURES = %w[business individual public]

    # Civilités d'un contact (vide : non précisée). Libellé : `crm.civilities.<code>`.
    CIVILITIES = %w[mr ms mx]

    # Bases légales de la prospection (RGPD, ADR-009 D2 ; vide : non
    # renseignée). Libellé : `crm.legal_bases.<code>`.
    LEGAL_BASES = %w[legitimate_interest consent contract]

    # Genres d'activité (ADR-009 D4). Libellé : `crm.activity_kinds.<code>`.
    ACTIVITY_KINDS = %w[call meeting email task note]

    # Genres d'étape : de travail, puis les deux étapes de clôture fixes.
    STAGE_KINDS = %w[open won lost]

    # Statuts d'une organisation (`crm.organization_statuses.<code>`) et
    # d'une opportunité (`crm.opportunity_statuses.<code>`).
    ORGANIZATION_STATUSES = %w[prospect customer]
    OPPORTUNITY_STATUSES  = %w[open won lost]

    # Délai de l'activité « relancer » créée au refus d'un devis (D-CRM-007).
    FOLLOW_UP_DAYS = 3

    # --- Entrées ---------------------------------------------------------------

    # Organisation (ADR-009 D2). `siren` : neuf chiffres (espaces ignorés) ;
    # `country_code` : code ISO à deux lettres, vide pour le pays du dossier.
    record OrganizationInput,
      name : String,
      nature : String = "business",
      siren : String = "",
      vat_number : String = "",
      email : String = "",
      phone : String = "",
      website : String = "",
      line1 : String = "",
      postcode : String = "",
      city : String = "",
      country_code : String = "",
      source_id : Int64? = nil,
      owner_id : Int64? = nil,
      notes : String = ""

    # « Devenir client » (ADR-009 D2) : nature du client du cœur ; catégorie
    # de fiches clients (`nil` : `CUSTOMER`, à défaut la première catégorie
    # de clients).
    record CustomerInput, nature : String = "business", category_id : Int64? = nil

    # Contact (ADR-009 D2). `legal_basis` : une des `LEGAL_BASES` ou vide ;
    # `legal_basis_on` : date de la base légale (défaut : aujourd'hui quand
    # la base est donnée).
    record ContactInput,
      last_name : String,
      first_name : String = "",
      organization_id : Int64? = nil,
      civility : String = "",
      job_title : String = "",
      email : String = "",
      phone : String = "",
      mobile : String = "",
      source_id : Int64? = nil,
      legal_basis : String = "",
      legal_basis_on : Time? = nil,
      notes : String = ""

    # Opportunité (ADR-009 D3). `stage_id` : `nil` pour la première étape de
    # travail (création seulement : on change d'étape par `move_opportunity`) ;
    # `probability` : `nil` pour celle de l'étape.
    record OpportunityInput,
      title : String,
      organization_id : Int64,
      contact_id : Int64? = nil,
      amount : BigDecimal = BigDecimal.new(0),
      probability : Int32? = nil,
      expected_close_on : Time? = nil,
      owner_id : Int64? = nil,
      stage_id : Int64? = nil,
      source_id : Int64? = nil

    # Changement d'étape : motif obligatoire pour « Perdue ».
    record MoveInput, stage_id : Int64, loss_reason_id : Int64? = nil, loss_note : String = ""

    # Activité (ADR-009 D4). `due_on` : `nil` pour aujourd'hui ; `starts_at` :
    # date et heure d'un appel ou d'un rendez-vous ; `duration_minutes` : de 0
    # à 14 400 ; une note est faite dès sa saisie.
    record ActivityInput,
      kind : String,
      subject : String,
      due_on : Time? = nil,
      starts_at : Time? = nil,
      duration_minutes : Int32? = nil,
      owner_id : Int64? = nil,
      report : String = "",
      done : Bool = false,
      organization_id : Int64? = nil,
      contact_id : Int64? = nil,
      opportunity_id : Int64? = nil

    # Étape (paramétrage) : `name` vide garde le libellé traduit d'une étape
    # initiale ; `probability` ignorée pour « Gagnée » et « Perdue ».
    record StageInput, name : String, probability : Int32 = 0, position : Int32 = 0, active : Bool = true

    # Motif de perte ou origine (paramétrage).
    record ChoiceInput, name : String, position : Int32 = 0, active : Bool = true

    record OrganizationQuery,
      search : String? = nil,
      status : String? = nil,
      owner_id : Int64? = nil,
      limit : Int32 = 500,
      offset : Int32 = 0

    # `opposed` : `false` (défaut) écarte les contacts opposés — listes
    # d'actions commerciales (ADR-009 D2) ; `true` ne rend qu'eux ; `nil`
    # rend tout.
    record ContactQuery,
      search : String? = nil,
      organization_id : Int64? = nil,
      opposed : Bool? = false,
      limit : Int32 = 500,
      offset : Int32 = 0

    # `status` : `open`, `won`, `lost` ou `nil` ; `no_next_step` : opportunités
    # ouvertes sans activité à venir (ADR-009 D4).
    record OpportunityQuery,
      search : String? = nil,
      stage_id : Int64? = nil,
      status : String? = nil,
      owner_id : Int64? = nil,
      organization_id : Int64? = nil,
      contact_id : Int64? = nil,
      no_next_step : Bool = false,
      limit : Int32 = 500,
      offset : Int32 = 0

    # `done` : `nil` pour toutes ; `owner_id` : responsable.
    record ActivityQuery,
      owner_id : Int64? = nil,
      done : Bool? = nil,
      organization_id : Int64? = nil,
      contact_id : Int64? = nil,
      opportunity_id : Int64? = nil,
      limit : Int32 = 500

    # Import CSV (ADR-009 D8) : contenu, correspondance des colonnes
    # (`en-tête` → champ de `IMPORT_FIELDS`, champ vide : colonne ignorée ;
    # `nil` : correspondance proposée d'après les en-têtes), base légale et
    # origine appliquées aux contacts importés qui n'en ont pas.
    record ImportInput,
      content : String,
      mapping : Hash(String, String)? = nil,
      legal_basis : String = "",
      source_id : Int64? = nil

    # Champs d'une ligne importée. Libellé : `crm.import.fields.<champ>`.
    IMPORT_FIELDS = %w[
      organization_name organization_nature organization_siren organization_vat_number organization_email
      organization_phone organization_website organization_line1 organization_postcode organization_city
      organization_country contact_civility contact_first_name contact_last_name contact_job_title contact_email
      contact_phone contact_mobile source legal_basis notes
    ]

    # --- Vues ------------------------------------------------------------------

    # Libellé d'un élément paramétrable : son nom, sinon la traduction de sa
    # valeur initiale (`crm.stages.proposal`).
    module Labelled
      def label : String
        return name unless name.empty?
        code.empty? ? "—" : I18n.t("#{label_scope}.#{code}")
      end
    end

    record StageView,
      id : Int64,
      code : String,
      name : String,
      position : Int32,
      probability : Int32,
      kind : String,
      active : Bool do
      include Labelled

      def label_scope : String
        "crm.stages"
      end

      def open? : Bool
        kind == "open"
      end

      def won? : Bool
        kind == "won"
      end

      def lost? : Bool
        kind == "lost"
      end

      def closing? : Bool
        !open?
      end
    end

    record ChoiceView, id : Int64, code : String, name : String, position : Int32, active : Bool, scope : String do
      include Labelled

      def label_scope : String
        scope
      end
    end

    # Utilisateur du dossier, responsable possible.
    record OwnerView, id : Int64, name : String

    record OrganizationView,
      id : Int64,
      name : String,
      nature : String,
      siren : String,
      vat_number : String,
      email : String,
      phone : String,
      website : String,
      line1 : String,
      postcode : String,
      city : String,
      country_code : String,
      card_id : Int64?,
      source_id : Int64?,
      owner_id : Int64?,
      notes : String,
      created_at : Time,
      updated_at : Time do
      def customer? : Bool
        !card_id.nil?
      end

      def prospect? : Bool
        card_id.nil?
      end

      def status : String
        customer? ? "customer" : "prospect"
      end

      def status_key : String
        "crm.organization_statuses.#{status}"
      end

      def nature_key : String
        "crm.natures.#{nature}"
      end

      def address : String
        [line1, "#{postcode} #{city}".strip, country_code].reject(&.empty?).join(", ")
      end
    end

    record ContactView,
      id : Int64,
      organization_id : Int64?,
      organization_name : String?,
      civility : String,
      first_name : String,
      last_name : String,
      job_title : String,
      email : String,
      phone : String,
      mobile : String,
      source_id : Int64?,
      legal_basis : String,
      legal_basis_on : Time?,
      opposed_at : Time?,
      opposition_note : String,
      notes : String,
      created_at : Time,
      updated_at : Time do
      def full_name : String
        "#{first_name} #{last_name}".strip
      end

      def opposed? : Bool
        !opposed_at.nil?
      end

      def legal_basis_key : String?
        legal_basis.empty? ? nil : "crm.legal_bases.#{legal_basis}"
      end

      def civility_key : String?
        civility.empty? ? nil : "crm.civilities.#{civility}"
      end
    end

    record OpportunityView,
      id : Int64,
      title : String,
      organization_id : Int64,
      organization_name : String,
      organization_customer : Bool,
      contact_id : Int64?,
      contact_name : String?,
      amount : BigDecimal,
      probability : Int32,
      expected_close_on : Time?,
      owner_id : Int64?,
      stage : StageView,
      source_id : Int64?,
      loss_reason_id : Int64?,
      loss_note : String,
      closed_at : Time?,
      next_activity_on : Time?,
      created_at : Time,
      updated_at : Time do
      def stage_id : Int64
        stage.id
      end

      # Montant pondéré par la probabilité (ADR-009 D3), arrondi au centime.
      def weighted_amount : BigDecimal
        (amount * probability / 100).round(2)
      end

      def status : String
        stage.kind
      end

      def status_key : String
        "crm.opportunity_statuses.#{status}"
      end

      def open? : Bool
        stage.open?
      end

      # Opportunité ouverte sans activité à venir (« sans suite prévue »,
      # ADR-009 D4).
      def no_next_step? : Bool
        open? && next_activity_on.nil?
      end
    end

    record StageChangeView,
      id : Int64,
      from_stage : StageView?,
      to_stage : StageView,
      user_id : Int64?,
      cause : String,
      created_at : Time do
      def cause_key : String?
        cause.empty? ? nil : "crm.history.#{cause}"
      end
    end

    # Devis ou facture de la Facturation rattaché à une opportunité, relu
    # par le contrat du cœur (`readable` : faux si l'acteur ne peut pas lire
    # la Facturation ou si le document n'existe plus).
    record DocumentView,
      id : Int64,
      document_id : Int64,
      kind : String,
      number : String?,
      status : String?,
      total_net : BigDecimal?,
      issue_date : Time?,
      readable : Bool,
      created_at : Time do
      def kind_key : String
        "invoicing.kinds.#{kind}"
      end

      def status_key : String?
        status.try { |code| "invoicing.statuses.#{code}" }
      end
    end

    record ActivityView,
      id : Int64,
      kind : String,
      subject : String,
      due_on : Time,
      starts_at : Time?,
      duration_minutes : Int32?,
      owner_id : Int64?,
      report : String,
      done : Bool,
      done_at : Time?,
      organization_id : Int64?,
      organization_name : String?,
      contact_id : Int64?,
      contact_name : String?,
      opportunity_id : Int64?,
      opportunity_title : String?,
      created_at : Time do
      def kind_key : String
        "crm.activity_kinds.#{kind}"
      end

      def late?(today : Time) : Bool
        !done && due_on < today
      end
    end

    # « Mes activités » (ADR-009 D4) : à faire en retard, aujourd'hui, à venir.
    record AgendaView, late : Array(ActivityView), today : Array(ActivityView), upcoming : Array(ActivityView)

    # Colonne du pipeline : étape, opportunités, montant et montant pondéré.
    record ColumnView, stage : StageView, opportunities : Array(OpportunityView) do
      def amount : BigDecimal
        opportunities.sum(BigDecimal.new(0), &.amount)
      end

      def weighted_amount : BigDecimal
        opportunities.sum(BigDecimal.new(0), &.weighted_amount)
      end
    end

    record PipelineView, columns : Array(ColumnView) do
      def open_columns : Array(ColumnView)
        columns.select(&.stage.open?)
      end

      def weighted_amount : BigDecimal
        open_columns.sum(BigDecimal.new(0), &.weighted_amount)
      end
    end

    # Ligne d'un total du tableau de bord : par étape ou par responsable.
    record TotalView, label : String, count : Int64, amount : BigDecimal, weighted_amount : BigDecimal, id : Int64? = nil

    record ReasonCountView, label : String, count : Int64

    # Tableau de bord commercial (ADR-009 D6) sur la période `from`..`to`.
    # `invoiced` : chiffre d'affaires HT facturé issu des opportunités, lu
    # dans la Facturation (`nil` sans droit de lecture de la Facturation).
    record DashboardView,
      from : Time,
      to : Time,
      by_stage : Array(TotalView),
      by_owner : Array(TotalView),
      won_count : Int64,
      won_amount : BigDecimal,
      lost_count : Int64,
      lost_amount : BigDecimal,
      loss_reasons : Array(ReasonCountView),
      late_activities : Int64,
      no_next_step : Int64,
      invoiced : BigDecimal?,
      invoiced_count : Int64 do
      def weighted_amount : BigDecimal
        by_stage.sum(BigDecimal.new(0), &.weighted_amount)
      end

      def open_count : Int64
        by_stage.sum(0_i64, &.count)
      end

      # Taux de transformation : gagnées / (gagnées + perdues), en
      # pourcentage ; `nil` sans opportunité close sur la période.
      def conversion_rate : BigDecimal?
        closed = won_count + lost_count
        return if closed.zero?
        (BigDecimal.new(won_count) * 100 / closed).round(1)
      end
    end

    # Tuile « Commercial » du tableau de bord du dossier (ADR-009 D6).
    record TileView, weighted_amount : BigDecimal, open_count : Int64, late_activities : Int64

    # Ligne d'un import CSV : numéro (en-tête = 1), valeurs par champ,
    # doublon repéré (`crm.import.duplicates.<cause>`, paramètre `name`),
    # erreurs.
    record ImportRowView,
      line : Int32,
      values : Hash(String, String),
      duplicate : String?,
      duplicate_of : String?,
      errors : Array(Partiduo::Api::FieldError) do
      def importable? : Bool
        duplicate.nil? && errors.empty?
      end
    end

    # Aperçu d'un import : en-têtes, correspondance proposée ou retenue,
    # séparateur reconnu, lignes.
    record ImportPreviewView,
      headers : Array(String),
      mapping : Hash(String, String),
      separator : Char,
      rows : Array(ImportRowView) do
      def importable_count : Int32
        rows.count(&.importable?)
      end
    end

    # Bilan d'un import : fiches créées, lignes écartées (doublons, erreurs).
    record ImportReportView, organizations : Int32, contacts : Int32, skipped : Array(ImportRowView)
  end
end
