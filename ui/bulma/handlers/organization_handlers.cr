# SPDX-License-Identifier: AGPL-3.0-or-later

module Crm
  module Ui
    # Formulaire d'une organisation (création, modification).
    abstract class OrganizationScreen < Handler
      FIELDS = %w[name nature siren vat_number email phone website line1 postcode city country_code source_id owner_id notes]

      def organization_crumbs(title : String? = nil, url : String? = nil) : Array(Screen::Crumb)
        list = crumbs({I18n.t("crm.menu.crm_organizations"), title ? Ui.url("organizations") : nil})
        list << Screen::Crumb.new(title, url) if title
        list
      end

      def values_of(view : Api::OrganizationView?) : Hash(String, String)
        return {"nature" => "business", "owner_id" => actor.user_id.to_s} unless view
        {
          "name" => view.name, "nature" => view.nature, "siren" => view.siren, "vat_number" => view.vat_number,
          "email" => view.email, "phone" => view.phone, "website" => view.website, "line1" => view.line1,
          "postcode" => view.postcode, "city" => view.city, "country_code" => view.country_code,
          "source_id" => view.source_id.to_s, "owner_id" => view.owner_id.to_s, "notes" => view.notes,
        }
      end

      def submitted : Hash(String, String)
        FIELDS.to_h { |name| {name, field(name, strip: name != "notes")} }
      end

      def organization_form(values : Hash(String, String), customer : Bool = false) : Form
        value = ->(name : String) { values[name]? || "" }
        identity = [
          Form::Field.new("name", I18n.t("crm_ui.organizations.name"), value: value.call("name"), required: true, maxlength: 200,
            wide: true),
          Form::Field.new("nature", I18n.t("crm_ui.organizations.nature"), "select", value.call("nature"),
            options: code_options(Api::NATURES, "crm.natures")),
          Form::Field.new("siren", I18n.t("crm_ui.organizations.siren"), value: value.call("siren"), mono: true, maxlength: 11),
          Form::Field.new("vat_number", I18n.t("crm_ui.organizations.vat_number"), value: value.call("vat_number"), mono: true,
            maxlength: 32),
        ]
        contact = [
          Form::Field.new("email", I18n.t("crm_ui.organizations.email"), "email", value.call("email"), maxlength: 254),
          Form::Field.new("phone", I18n.t("crm_ui.organizations.phone"), value: value.call("phone"), maxlength: 32),
          Form::Field.new("website", I18n.t("crm_ui.organizations.website"), value: value.call("website"), maxlength: 200),
          Form::Field.new("line1", I18n.t("crm_ui.organizations.line1"), value: value.call("line1"), maxlength: 200, wide: true),
          Form::Field.new("postcode", I18n.t("crm_ui.organizations.postcode"), value: value.call("postcode"), maxlength: 16),
          Form::Field.new("city", I18n.t("crm_ui.organizations.city"), value: value.call("city"), maxlength: 100),
          Form::Field.new("country_code", I18n.t("crm_ui.organizations.country"), value: value.call("country_code"), mono: true,
            maxlength: 2, help: I18n.t("crm_ui.organizations.country_help")),
        ]
        follow = [
          Form::Field.new("owner_id", I18n.t("crm_ui.organizations.owner"), "select", value.call("owner_id"), options: owner_options),
          Form::Field.new("source_id", I18n.t("crm_ui.organizations.source"), "select", value.call("source_id"), options: source_options),
          Form::Field.new("notes", I18n.t("crm_ui.organizations.notes"), "textarea", value.call("notes"), wide: true),
        ]
        groups = [Form::Group.new(nil, identity), Form::Group.new(I18n.t("crm_ui.organizations.contact_group"), contact),
                  Form::Group.new(I18n.t("crm_ui.organizations.follow_group"), follow)]
        Form.new(groups)
      end

      def read_input : Api::OrganizationInput
        Api::OrganizationInput.new(name: field("name"), nature: field("nature"), siren: field("siren"),
          vat_number: field("vat_number"), email: field("email"), phone: field("phone"), website: field("website"),
          line1: field("line1"), postcode: field("postcode"), city: field("city"), country_code: field("country_code"),
          source_id: id_field("source_id"), owner_id: id_field("owner_id"), notes: field("notes", strip: false))
      end
    end

    # `/ext/CRM/organizations` : prospects et clients, filtrables, export CSV.
    class OrganizationsHandler < OrganizationScreen
      def get
        status = Api::ORGANIZATION_STATUSES.includes?(query("status")) ? query("status") : nil
        views = Api.organizations(actor, Api::OrganizationQuery.new(status: status, owner_id: query("owner").to_i64?,
          limit: Api::MAX_LIMIT))
        params = {"q" => query("q"), "status" => query("status"), "owner" => query("owner")}.reject { |_, value| value.empty? }
        actions = [] of Screen::Action
        if can_write?
          actions << link_action("crm.menu.crm_import", Ui.url("import"), "", "upload")
          actions << link_action("crm_ui.organizations.new", Ui.url("organization_new"), "primary", "plus")
        end
        list_page(I18n.t("crm.menu.crm_organizations"), table(views, params), crumbs, "crm_ui.organizations.csv_name", actions,
          filters: filters)
      end

      private def filters : Form
        statuses = [option("", I18n.t("crm_ui.organizations.all_statuses"))] +
                   Api::ORGANIZATION_STATUSES.map { |code| option(code, I18n.t("crm.organization_statuses.#{code}")) }
        Form.new([Form::Group.new(nil, [
          Form::Field.new("q", I18n.t("ui.table.search"), value: query("q"), placeholder: I18n.t("crm_ui.organizations.search")),
          Form::Field.new("status", I18n.t("crm_ui.organizations.status"), "select", query("status"), options: statuses),
          Form::Field.new("owner", I18n.t("crm_ui.organizations.owner"), "select", query("owner"),
            options: [option("", I18n.t("crm_ui.opportunities.all_owners"))] + owner_options(blank: false)),
        ])])
      end

      private def table(views : Array(Api::OrganizationView), params : Hash(String, String)) : Table
        columns = [
          Table::Column.new("name", I18n.t("crm_ui.organizations.name")),
          Table::Column.new("status", I18n.t("crm_ui.organizations.status")),
          Table::Column.new("city", I18n.t("crm_ui.organizations.city"), secondary: true),
          Table::Column.new("siren", I18n.t("crm_ui.organizations.siren"), "mono", secondary: true),
          Table::Column.new("email", I18n.t("crm_ui.organizations.email"), secondary: true),
          Table::Column.new("phone", I18n.t("crm_ui.organizations.phone"), secondary: true),
          Table::Column.new("owner", I18n.t("crm_ui.organizations.owner"), secondary: true),
        ]
        rows = views.map do |view|
          Table::Row.new([
            Table::Cell.new(view.name, Ui.url("organization", id: view.id)),
            Table::Cell.new(I18n.t(view.status_key)),
            Table::Cell.new(view.city),
            Table::Cell.new(view.siren),
            Table::Cell.new(view.email),
            Table::Cell.new(view.phone),
            Table::Cell.new(view.owner_id.try { |id| owners[id]? } || ""),
          ])
        end
        Table.new(I18n.t("crm.menu.crm_organizations"), columns, rows, Ui.url("organizations"), params,
          I18n.t("crm_ui.organizations.none"), "crm-organizations")
      end
    end

    class OrganizationNewHandler < OrganizationScreen
      def get
        show(organization_form(values_of(nil)))
      end

      def post
        result = Api.create_organization(actor, read_input)
        if view = result.value?
          flash["success"] = I18n.t("crm_ui.flash.organization_created")
          return go(Ui.url("organization", id: view.id))
        end
        show(organization_form(submitted).add_errors(result.errors, fmt))
      end

      private def show(form : Form) : Marten::HTTP::Response
        title = I18n.t("crm_ui.organizations.new")
        form_page(title, organization_crumbs(title), form, Ui.url("organization_new"), I18n.t("ui.forms.create"),
          Ui.url("organizations"), intro: I18n.t("crm_ui.organizations.prospect_help"))
      end
    end

    class OrganizationEditHandler < OrganizationScreen
      def get
        view = Api.organization(actor, id_param)
        show(view, organization_form(values_of(view)))
      end

      def post
        view = Api.organization(actor, id_param)
        result = Api.update_organization(actor, view.id, read_input)
        if result.success?
          flash["success"] = I18n.t("crm_ui.flash.saved")
          return go(Ui.url("organization", id: view.id))
        end
        show(view, organization_form(submitted).add_errors(result.errors, fmt))
      end

      private def show(view : Api::OrganizationView, form : Form) : Marten::HTTP::Response
        url = Ui.url("organization", id: view.id)
        form_page(I18n.t("crm_ui.organizations.edit"), organization_crumbs(view.name, url), form,
          Ui.url("organization_edit", id: view.id), I18n.t("ui.forms.save"), url,
          intro: view.customer? ? I18n.t("crm_ui.organizations.customer_help") : nil)
      end
    end

    # `/ext/CRM/organizations/<id>` : coordonnées, fiche client, contacts,
    # opportunités, activités.
    class OrganizationHandler < OrganizationScreen
      def get
        view = Api.organization(actor, id_param)
        sections = [summary(view), contacts(view), opportunities(view),
                    Screen::Section.new(I18n.t("crm_ui.activities.title"),
                      table: Ui.activity_table(self, Api.activities(actor, Api::ActivityQuery.new(organization_id: view.id)),
                        Ui.url("organization", id: view.id), "crm-organization-activities"))]
        detail_page(view.name, organization_crumbs(view.name), sections, actions(view), I18n.t(view.status_key))
      end

      private def actions(view : Api::OrganizationView) : Array(Screen::Action)
        list = [] of Screen::Action
        if can_write?
          if view.prospect? && can?(Api::CUSTOMER_PERMISSION)
            list << link_action("crm_ui.organizations.become_customer", Ui.url("organization_customer", id: view.id), "primary", "user")
          end
          list << link_action("crm_ui.opportunities.new", "#{Ui.url("opportunity_new")}?organization=#{view.id}", "", "plus")
          list << link_action("crm_ui.contacts.new", "#{Ui.url("contact_new")}?organization=#{view.id}", "", "user")
          list << link_action("crm_ui.activities.new", "#{Ui.url("activity_new")}?organization=#{view.id}", "", "calendar")
          list << link_action("ui.forms.edit", Ui.url("organization_edit", id: view.id), "", "notebook-pen")
        end
        if can_admin? && view.prospect?
          list << post_action("crm_ui.organizations.delete", Ui.url("organization_delete", id: view.id),
            "crm_ui.organizations.delete_confirm", "danger", "x")
        end
        list
      end

      private def summary(view : Api::OrganizationView) : Screen::Section
        card_url = view.card_id.try { |id| can?("cards.card.read") ? Ui.route("cards:show", id: id) : nil }
        items = [
          Screen::Item.new(I18n.t("crm_ui.organizations.status"), I18n.t(view.status_key)),
          Screen::Item.new(I18n.t("crm_ui.organizations.card"), view.card_id ? I18n.t("crm_ui.organizations.card_link") : "", card_url),
          Screen::Item.new(I18n.t("crm_ui.organizations.nature"), I18n.t(view.nature_key)),
          Screen::Item.new(I18n.t("crm_ui.organizations.siren"), view.siren, mono: true),
          Screen::Item.new(I18n.t("crm_ui.organizations.vat_number"), view.vat_number, mono: true),
          Screen::Item.new(I18n.t("crm_ui.organizations.email"), view.email, view.email.empty? ? nil : "mailto:#{view.email}"),
          Screen::Item.new(I18n.t("crm_ui.organizations.phone"), view.phone, view.phone.empty? ? nil : "tel:#{view.phone.gsub(/\s+/, "")}"),
          Screen::Item.new(I18n.t("crm_ui.organizations.website"), view.website),
          Screen::Item.new(I18n.t("crm_ui.organizations.address"), view.address),
          Screen::Item.new(I18n.t("crm_ui.organizations.owner"), view.owner_id.try { |id| owners[id]? } || ""),
          Screen::Item.new(I18n.t("crm_ui.organizations.source"),
            view.source_id.try { |id| Api.sources(actor).find(&.id.==(id)).try(&.label) } || ""),
          Screen::Item.new(I18n.t("crm_ui.organizations.notes"), view.notes),
        ]
        Screen::Section.new(I18n.t("crm_ui.organizations.summary"), items)
      end

      private def contacts(view : Api::OrganizationView) : Screen::Section
        columns = [
          Table::Column.new("name", I18n.t("crm_ui.contacts.name")),
          Table::Column.new("job", I18n.t("crm_ui.contacts.job_title"), secondary: true),
          Table::Column.new("email", I18n.t("crm_ui.contacts.email")),
          Table::Column.new("phone", I18n.t("crm_ui.contacts.phone"), secondary: true),
        ]
        rows = Api.contacts(actor, Api::ContactQuery.new(organization_id: view.id, opposed: nil)).map do |contact|
          Table::Row.new([
            Table::Cell.new(contact.full_name, Ui.url("contact", id: contact.id), tag: contact.opposed? ? I18n.t("crm_ui.contacts.opposed") : nil),
            Table::Cell.new(contact.job_title), Table::Cell.new(contact.email), Table::Cell.new(contact.phone.presence || contact.mobile),
          ])
        end
        table = Table.new(I18n.t("crm.menu.crm_contacts"), columns, rows, Ui.url("organization", id: view.id),
          empty_message: I18n.t("crm_ui.contacts.none"), id: "crm-organization-contacts")
        table.exportable = false
        Screen::Section.new(I18n.t("crm.menu.crm_contacts"), table: table)
      end

      private def opportunities(view : Api::OrganizationView) : Screen::Section
        columns = [
          Table::Column.new("title", I18n.t("crm_ui.opportunities.title_field")),
          Table::Column.new("stage", I18n.t("crm_ui.opportunities.stage")),
          Table::Column.new("amount", I18n.t("crm_ui.opportunities.amount"), "amount"),
          Table::Column.new("close_on", I18n.t("crm_ui.opportunities.close_on"), "mono", secondary: true),
        ]
        rows = Api.opportunities(actor, Api::OpportunityQuery.new(organization_id: view.id)).map do |opportunity|
          Table::Row.new([
            Table::Cell.new(opportunity.title, Ui.url("opportunity", id: opportunity.id)),
            Table::Cell.new(opportunity.stage.label),
            Table::Cell.new(fmt.amount(opportunity.amount), sort: opportunity.amount),
            Table::Cell.new(opportunity.expected_close_on.try { |date| fmt.date(date) } || "", sort: date_key(opportunity.expected_close_on)),
          ])
        end
        table = Table.new(I18n.t("crm.menu.crm_opportunities"), columns, rows, Ui.url("organization", id: view.id),
          empty_message: I18n.t("crm_ui.opportunities.none"), id: "crm-organization-opportunities")
        table.exportable = false
        Screen::Section.new(I18n.t("crm.menu.crm_opportunities"), table: table)
      end
    end

    # `/ext/CRM/organizations/<id>/customer` : « Devenir client » (ADR-009
    # D2), action explicite : nature du client et catégorie de fiches.
    class OrganizationCustomerHandler < OrganizationScreen
      def get
        view = Api.organization(actor, id_param)
        show(view, customer_form(view.nature, ""))
      end

      def post
        view = Api.organization(actor, id_param)
        input = Api::CustomerInput.new(nature: field("nature"), category_id: id_field("category_id"))
        result = Api.become_customer(actor, view.id, input)
        if result.success?
          flash["success"] = I18n.t("crm_ui.flash.customer")
          return go(Ui.url("organization", id: view.id))
        end
        show(view, customer_form(field("nature"), field("category_id")).add_errors(result.errors, fmt))
      end

      private def customer_form(nature : String, category : String) : Form
        categories = [option("", I18n.t("crm_ui.organizations.default_category"))] +
                     Partiduo::Api::Cards.categories(actor, "customer").map { |item| option(item.id.to_s, item.name) }
        Form.new([Form::Group.new(nil, [
          Form::Field.new("nature", I18n.t("crm_ui.organizations.nature"), "select", nature,
            options: code_options(Api::NATURES, "crm.natures"), help: I18n.t("crm_ui.organizations.nature_help")),
          Form::Field.new("category_id", I18n.t("crm_ui.organizations.category"), "select", category, options: categories),
        ])])
      end

      private def show(view : Api::OrganizationView, form : Form) : Marten::HTTP::Response
        url = Ui.url("organization", id: view.id)
        title = I18n.t("crm_ui.organizations.become_customer")
        form_page(title, organization_crumbs(view.name, url) << Screen::Crumb.new(title), form,
          Ui.url("organization_customer", id: view.id), I18n.t("crm_ui.organizations.become_customer_submit"), url,
          intro: I18n.t("crm_ui.organizations.become_customer_intro", name: view.name))
      end
    end

    class OrganizationDeleteHandler < Handler
      def get
        go(Ui.url("organization", id: id_param))
      end

      def post
        result = Api.delete_organization(actor, id_param)
        return after(result, "crm_ui.flash.deleted", Ui.url("organizations")) if result.success?
        after(result, "crm_ui.flash.deleted", Ui.url("organization", id: id_param))
      end
    end
  end
end
