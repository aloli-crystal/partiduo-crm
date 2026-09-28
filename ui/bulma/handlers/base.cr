# SPDX-License-Identifier: AGPL-3.0-or-later

module Crm
  module Ui
    # Base des écrans de l'extension, sur celle des écrans du référentiel de
    # l'interface (listes, formulaires, consultations des gabarits
    # `ui/reference/*.html`) : fil d'Ariane « Relation client › … », listes
    # de choix des formulaires, lecture des champs. L'accès a déjà été contrôlé par
    # `PartiduoUi::ExtensionHandler` à partir du montage ; `Crm::Api` vérifie
    # encore la permission de chaque commande.
    abstract class Handler < PartiduoUi::ReferenceHandler
      alias Api = Crm::Api
      alias Form = PartiduoUi::Form
      alias Table = PartiduoUi::Table
      alias Screen = PartiduoUi::Screen

      def actor : Partiduo::Api::Actor
        current.actor
      end

      def crumbs : Array(Screen::Crumb)
        [crumb("crm.menu.crm")]
      end

      def crumbs(*items : {String, String?}) : Array(Screen::Crumb)
        list = [crumb("crm.menu.crm")]
        items.each { |(label, url)| list << Screen::Crumb.new(label, url) }
        list
      end

      def can_write? : Bool
        can?(Api::WRITE)
      end

      def can_admin? : Bool
        can?(Api::ADMIN)
      end

      @owners : Hash(Int64, String)?

      # Noms des responsables possibles, par identifiant.
      def owners : Hash(Int64, String)
        @owners ||= Api.owners(actor).to_h { |owner| {owner.id, owner.name} }
      end

      # --- Lecture des champs ---------------------------------------------------------

      def id_field(name : String) : Int64?
        field(name).to_i64?
      end

      def int_field(name : String) : Int32?
        field(name).to_i32?
      end

      # Montant saisi selon la langue (`1 234,56`) ; `nil` si vide ou illisible.
      def decimal_field(name : String) : BigDecimal?
        text = field(name)
        text.empty? ? nil : fmt.parse_decimal(text)
      end

      # Date d'un champ `date` (AAAA-MM-JJ), ou saisie selon la langue.
      def date_field(name : String) : Time?
        Ui.parse_date(field(name), fmt)
      end

      # --- Listes de choix -------------------------------------------------------------

      def blank_option(label_key : String = "crm_ui.forms.none") : Form::Option
        option("", I18n.t(label_key))
      end

      def owner_options(blank : Bool = true) : Array(Form::Option)
        list = owners.to_a.sort_by!(&.[1]).map { |(id, name)| option(id.to_s, name) }
        blank ? [blank_option] + list : list
      end

      def source_options : Array(Form::Option)
        [blank_option] + Api.sources(actor, active_only: true).map { |source| option(source.id.to_s, source.label) }
      end

      def organization_options(blank : Bool = false) : Array(Form::Option)
        list = Api.organizations(actor).map { |organization| option(organization.id.to_s, organization.name) }
        blank ? [blank_option] + list : [option("", I18n.t("crm_ui.forms.choose"))] + list
      end

      # Contacts utilisables pour une action commerciale (non opposés),
      # avec leur organisation.
      def contact_options : Array(Form::Option)
        [blank_option] + Api.contacts(actor).map do |contact|
          label = contact.organization_name ? "#{contact.full_name} · #{contact.organization_name}" : contact.full_name
          option(contact.id.to_s, label)
        end
      end

      def opportunity_options : Array(Form::Option)
        [blank_option] + Api.opportunities(actor, Api::OpportunityQuery.new(status: "open")).map do |opportunity|
          option(opportunity.id.to_s, "#{opportunity.title} · #{opportunity.organization_name}")
        end
      end

      def code_options(codes : Array(String), scope : String, blank : Bool = false) : Array(Form::Option)
        list = codes.map { |code| option(code, I18n.t("#{scope}.#{code}")) }
        blank ? [blank_option] + list : list
      end

      def listed_actions(actions : Array(Screen::Action)) : Array(Screen::Action)?
        listed(actions)
      end

      # Redirection après une commande, avec le message du résultat.
      def after(result, success_key : String, url : String) : Marten::HTTP::Response
        if result.success?
          flash["success"] = I18n.t(success_key)
        else
          flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
        end
        go(url)
      end
    end

    # Date d'un champ : ISO (`2026-09-28`, champ `date`) ou saisie selon la
    # langue (`28/09/2026`).
    def self.parse_date(text : String, fmt : PartiduoUi::Format) : Time?
      value = text.strip
      return if value.empty?
      begin
        Time.parse_utc(value, "%Y-%m-%d")
      rescue Time::Format::Error
        fmt.parse_date(value)
      end
    end

    def self.iso(date : Time?) : String
      date.try(&.to_s("%Y-%m-%d")) || ""
    end
  end
end
