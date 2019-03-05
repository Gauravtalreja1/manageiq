class ServiceOrchestration < Service
  include ServiceOrchestrationMixin
  include ServiceOrchestrationOptionsMixin
  include_concern 'ProvisionTagging'

  # read from DB or parse from dialog
  def stack_name
    @stack_name ||= options.fetch_path(:orchestration_stack, 'name')
    @stack_name ||= options.fetch_path(:stack_name) # required only for backward compatibility purpose
    @stack_name ||= OptionConverter.get_stack_name(options[:dialog] || {})
  end

  # override existing stack name (most likely from dialog)
  def stack_name=(stname)
    @stack_name = stname
    options.store_path(:orchestration_stack, 'name', stname)
  end

  def orchestration_stack_status
    return ['deploy_failed', "can't find orchestration stack job for the service"] unless orchestration_runner_job

    return ['deploy_failed', orchestration_runner_job.message] if orchestration_runner_job.status == 'error'

    return ['deploy_active', 'waiting for the orchestration stack status'] unless orchestration_runner_job.orchestration_stack_status

    [orchestration_runner_job.orchestration_stack_status, orchestration_runner_job.orchestration_stack_message]
  end

  def deploy_orchestration_stack
    deploy_stack_options = stack_options
    job_options = {
      :create_options            => deploy_stack_options,
      :orchestration_manager_id  => orchestration_manager.id,
      :orchestration_template_id => orchestration_template.id,
      :stack_name                => stack_name,
      :zone                      => my_zone
    }

    @deploy_stack_job = ManageIQ::Providers::CloudManager::OrchestrationTemplateRunner.create_job(job_options)
    update_attributes(:options => options.merge(:deploy_stack_job_id => @deploy_stack_job.id))
    @deploy_stack_job.signal(:start)

    wait_on_orchestration_stack
    orchestration_stack
  ensure
    # create options may never be saved before unless they were overridden
    save_create_options
  end

  def update_orchestration_stack
    job_options = {
      # use orchestration_template from service_template, which may be different from existing orchestration_template
      :orchestration_template_id => service_template.orchestration_template.id,
      :orchestration_stack_id    => orchestration_stack.id,
      :update_options            => update_options,
      :zone                      => my_zone
    }
    @update_stack_job = ManageIQ::Providers::CloudManager::OrchestrationTemplateRunner.create_job(job_options)
    update_attributes(:options => options.merge(:update_stack_job_id => @update_stack_job.id))
    @update_stack_job.signal(:update)
  end

  def orchestration_stack
    @orchestration_stack ||= service_resources.find { |sr| sr.resource.kind_of?(OrchestrationStack) }.try(:resource)

    # ems_id is a good indication that the stack object can be reconstructed and connect to its provider
    if @orchestration_stack.nil? && options.fetch_path(:orchestration_stack, 'ems_id')
      @orchestration_stack = OrchestrationStack.new(options[:orchestration_stack])
    end

    @orchestration_stack
  end

  def build_stack_options_from_dialog(dialog_options)
    tenant_name = OptionConverter.get_tenant_name(dialog_options)
    tenant_option = tenant_name.blank? ? {} : {:tenant_name => tenant_name}

    converter = OptionConverter.get_converter(dialog_options || {}, orchestration_manager.class)
    converter.stack_create_options.merge(tenant_option)
  end

  def indirect_vms
    return [] if orchestration_stack.nil? || orchestration_stack.new_record?
    orchestration_stack.indirect_vms
  end

  def direct_vms
    return [] if orchestration_stack.nil? || orchestration_stack.new_record?

    # Loading all VMs, to make listing of the VMs under Service work, when we deal with nested stacks. A proper fix
    # would be to use something like closure_tree, where we can build tree from the multiple classes. Then Service level
    # MiqPreloader.preload_and_map(subtree, :direct_vms) will work also for nested stacks. Because in that case, nested
    # stacks will be a part of the subtree.
    orchestration_stack.vms
  end

  def all_vms
    return [] if orchestration_stack.nil? || orchestration_stack.new_record?
    orchestration_stack.vms
  end

  # This is called when provision is completed and stack is added to VMDB through a refresh
  def post_provision_configure
    add_stack_to_resource
    link_orchestration_template
    assign_vms_owner
    apply_provisioning_tags
  end

  def my_zone
    orchestration_manager.try(:my_zone) || super
  end

  private

  def add_stack_to_resource
    @orchestration_stack = OrchestrationStack.find_by(
      :ems_ref => options.fetch_path(:orchestration_stack, 'ems_ref'),
      :ems_id  => options.fetch_path(:orchestration_stack, 'ems_id')
    )
    add_resource!(@orchestration_stack) if @orchestration_stack
  end

  def link_orchestration_template
    # some orchestration stacks do not have associations with their templates in their provider, we can link them here
    return if orchestration_stack.nil? || orchestration_stack.orchestration_template
    orchestration_stack.update_attributes(:orchestration_template => orchestration_template)
  end

  def assign_vms_owner
    all_vms.each do |vm|
      vm.update_attributes(:evm_owner_id => evm_owner_id, :miq_group_id => miq_group_id)
    end
  end

  def build_stack_create_options
    dialog_options = options[:dialog] || {}
    pick_orchestration_manager(dialog_options)
    pick_orchestration_template(dialog_options)

    build_stack_options_from_dialog(dialog_options)
  end

  # The order to pick the orchestration manager and template
  # 1. The ones directly set through setter
  # 2. The ones set through dialog options
  # 3. The ones copied from service_template
  def pick_orchestration_manager(dialog_options)
    if orchestration_manager == service_template.orchestration_manager
      manager_from_dialog = OptionConverter.get_manager(dialog_options)
      self.orchestration_manager = manager_from_dialog if manager_from_dialog
    end
    raise _("orchestration manager was not set") if orchestration_manager.nil?
  end

  def pick_orchestration_template(dialog_options)
    if orchestration_template == service_template.orchestration_template
      template_from_dialog = OptionConverter.get_template(dialog_options)
      self.orchestration_template = template_from_dialog if template_from_dialog
    end
    raise _("orchestration template was not set") if orchestration_template.nil?
  end

  def save_create_options
    stack_attributes = orchestration_stack ?
                       orchestration_stack.attributes.compact :
                       {:name => stack_name}
    stack_attributes.delete('id')
    options.merge!(:orchestration_stack => stack_attributes,
                   :create_options      => dup_and_process_password(stack_options))
    save!
  end

  def deploy_stack_job
    @deploy_stack_job ||= Job.find_by(:id => options.fetch_path(:deploy_stack_job_id))
  end

  def update_stack_job
    @update_stack_job ||= Job.find_by(:id => options.fetch_path(:update_stack_job_id))
  end

  def orchestration_runner_job
    update_stack_job || deploy_stack_job
  end

  def wait_on_orchestration_stack
    while deploy_stack_job.orchestration_stack.blank?
      _log.info("Waiting for the deployment of orchestration stack [#{stack_name}]...")
      sleep 2
      # Code running with Rails QueryCache enabled,
      # need to disable caching for the reload to see updates.
      self.class.uncached { reload }
      deploy_stack_job.class.uncached { deploy_stack_job.reload }
    end
    @orchestration_stack = deploy_stack_job.orchestration_stack
  end
end
