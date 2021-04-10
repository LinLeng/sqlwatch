﻿CREATE PROCEDURE [dbo].[usp_sqlwatch_logger_xes_blockers]
AS

set nocount on;
set xact_abort on;

if [dbo].[ufn_sqlwatch_get_product_version]('major') >= 11
	begin

		declare @execution_count bigint = 0,
				@session_name nvarchar(64) = 'SQLWATCH_Blockers',
				@address varbinary(8)

		--we're getting session address in a separate batch
		--becuase when we join xe_sessions with xe_session_targets
		--the execution goes up to 500ms. two batches run in 4 ms.
		select @address = address 
		from sys.dm_xe_sessions
		where name = @session_name
		option (keepfixed plan)

		select @execution_count = isnull(execution_count,0)
		from sys.dm_xe_session_targets t
		where event_session_address = @address
		option (keepfixed plan)

		--if the session has not triggered since last run there will not be any new records so we may not bother querying it
		if @execution_count > (
			select execution_count
			from [dbo].[sqlwatch_stage_xes_exec_count]
			where session_name = @session_name
			)
			begin
				--update execution count
				update [dbo].[sqlwatch_stage_xes_exec_count]
				set execution_count = @execution_count
				where session_name = @session_name;

				/* for this to work you must enable blocked process monitor */
				--inspired by and based on Michael J Stewart http://michaeljswart.com/2016/02/look-at-blocked-process-reports-collected-with-extended-events/

				declare @snapshot_time datetime,
						@snapshot_type_id tinyint = 9,
						@filename varchar(8000),
						@utc_offset_minute int = [dbo].[ufn_sqlwatch_get_server_utc_offset]('MINUTE')

				declare @event_data table (event_data xml)

				insert into @event_data
				select cast(event_data as xml)
				from sys.fn_xe_file_target_read_file ('SQLWATCH_blockers*.xel', null, null, null) t

				begin transaction

					exec [dbo].[usp_sqlwatch_internal_insert_header] 
						@snapshot_time_new = @snapshot_time OUTPUT,
						@snapshot_type_id = @snapshot_type_id

						merge [dbo].[sqlwatch_logger_xes_blockers] as target
						using 
							(
							select 
								  attach_activity_id
								, attach_activity_sequence
								, blocking_start_time
								, blocking_end_time
								, blocked_ecid
								, blocked_spid
								, blocked_sql
								, [database name]
								, lock_mode
								, blocking_ecid
								, blocking_spid
								, blocking_sql
								, blocking_duration_ms
								, [blocking_client app name]
								, [blocking_client hostname]
								, report_xml
								, snapshot_time = @snapshot_time
								, snapshot_type_id = @snapshot_type_id
								, [sql_instance] = @@SERVERNAME
							from (
								select 
									 [attach_activity_id]=substring(bps.[attach_activity_id],1,len(bps.[attach_activity_id])-charindex('-',reverse(bps.[attach_activity_id]))) 
									,[attach_activity_sequence]=right(bps.[attach_activity_id],charindex('-',reverse(bps.[attach_activity_id]))-1)
									,blocking_start_time = dateadd(ms,-bps.[blocking_duration_ms],bps.[report_end_time])
									,blocking_end_time=bps.[report_end_time]
									,bps.blocked_ecid
									,bps.blocked_spid
									,bps.blocked_sql
									,bps.[database name]
									,bps.[lock_mode]
									,bps.blocking_ecid
									,bps.blocking_spid
									,bps.blocking_sql
									,bps.[blocking_duration_ms]
									,bps.[blocking_client app name]
									,bps.[blocking_client hostname]
									,bps.report_xml
									/* SQL starts logging blocking chains as soon as they reach thresholds and NOT once the blocking chain has finished
										this means we are going to get multiple entries per each chain until it has finished. we can go ahead and remove any previous
										records of the same chain */
									,session_blocking_sequence = row_number() over (partition by convert(datetime2(0),dateadd(ms,-bps.[blocking_duration_ms],bps.[report_end_time]))
																												, bps.blocked_spid
																												, bps.[database name]
																												, bps.blocking_spid
																												, bps.[blocking_client app name]
																												, bps.[blocking_client hostname] 
																										order by bps.[blocking_duration_ms] desc)
								from @event_data xet
								cross apply ( select xet.event_data ) AS target_data ([xml])
								cross apply target_data.[xml].nodes('/event[@name="blocked_process_report"]') AS bp_nodes(bp_node)
								cross apply bp_node.nodes('./data[@name="blocked_process"]/value/blocked-process-report') AS bp_report_xml_nodes(bp_report_xml_node)
								cross apply
									(
										select 
										 [report_xml] = cast(bp_report_xml_node.query('.') as xml)
										 --https://github.com/marcingminski/sqlwatch/issues/169
										 --timestamp is UTC, adjust for local time:
										,[report_end_time] = dateadd(minute,@utc_offset_minute,bp_node.value('(./@timestamp)[1]', 'datetime'))
										,[monitor_loop] = bp_report_xml_node.value('(//@monitorLoop)[1]', 'nvarchar(100)')
										,[blocked_spid] = bp_report_xml_node.value('(./blocked-process/process/@spid)[1]', 'int')
										,[blocked_ecid] = bp_report_xml_node.value('(./blocked-process/process/@ecid)[1]', 'int')
										,[blocked_sql] = bp_report_xml_node.value('(./blocked-process/process/inputbuf)[1]', 'nvarchar(max)')
										,[client app name] = bp_node.value('(./action[@name="client app name"]/value)[1]', 'nvarchar(128)')
										,[database name] = nullif(bp_node.value('(./data[@name="database_name"]/value)[1]', 'nvarchar(128)'),'')
										,[lock_mode]=bp_node.value('(./data[@name="lock_mode"]/text)[1]', 'varchar(50)')
										,[blocking_spid] = bp_report_xml_node.value('(./blocking-process/process/@spid)[1]', 'int')
										,[blocking_ecid] = bp_report_xml_node.value('(./blocking-process/process/@ecid)[1]', 'int')
										,[blocking_sql] = bp_report_xml_node.value('(./blocking-process/process/inputbuf)[1]', 'varchar(max)')
										,[blocking_duration_ms] = bp_node.value('(./data[@name="duration"]/value)[1]', 'bigint')/1000
										,[blocking_username]=bp_report_xml_node.value('(./action[@name="username"]/value)[1]', 'nvarchar(128)')
										,[blocking_client app name] = bp_report_xml_node.value('(./blocking-process/process/@clientapp)[1]', 'nvarchar(128)')
										,[blocking_client hostname] = bp_report_xml_node.value('(./blocking-process/process/@hostname)[1]', 'nvarchar(128)')
										,[attach_activity_id] = bp_node.value('(./action[@name="attach_activity_id"]/value )[1]', 'varchar(255)')
									) AS bps
								left join [dbo].[sqlwatch_logger_xes_blockers] t
									on t.attach_activity_id = substring(bps.[attach_activity_id],1,len(bps.[attach_activity_id])-charindex('-',reverse(bps.[attach_activity_id]))) 
									and t.attach_activity_sequence = right(bps.[attach_activity_id],charindex('-',reverse(bps.[attach_activity_id]))-1)
								where t.attach_activity_id is null
							) t
							where session_blocking_sequence = 1
						) as source
						/* if a blocking chain already exists, we are going to update it with the most recent data as per the comment above */
						on      source.[sql_instance] = target.[sql_instance]
							and source.[blocked_ecid] = target.[blocked_ecid]
							and source.[blocked_spid] = target.[blocked_spid]
							and source.[blocked_sql] = target.[blocked_sql]
							and source.[database name] = target.[database_name]
							and source.[lock_mode] = target.[lock_mode]
							and source.[blocking_ecid] = target.[blocking_ecid]
							and source.[blocking_spid] = target.[blocking_spid]
							and source.[blocking_sql] = target.[blocking_sql]
							and source.[blocking_client app name] = target.[blocking_client_app_name]
							and source.[blocking_client hostname] = target.[blocking_client_hostname]
							and convert(datetime2(0),source.blocking_start_time) = convert(datetime2(0),target.blocking_start_time) --it may vary by few miliseconds

						when not matched then
							insert (  attach_activity_id
									, attach_activity_sequence
									, blocking_start_time
									, blocking_end_time
									, blocked_ecid
									, blocked_spid
									, blocked_sql
									, [database_name]
									, lock_mode
									, blocking_ecid
									, blocking_spid
									, blocking_sql
									, blocking_duration_ms
									, [blocking_client_app_name]
									, [blocking_client_hostname]
									, report_xml
									, snapshot_time
									, snapshot_type_id)
							values (  source.attach_activity_id
									, source.attach_activity_sequence
									, source.blocking_start_time
									, source.blocking_end_time
									, source.blocked_ecid
									, source.blocked_spid
									, source.blocked_sql
									, source.[database name]
									, source.lock_mode
									, source.blocking_ecid
									, source.blocking_spid
									, source.blocking_sql
									, source.blocking_duration_ms
									, source.[blocking_client app name]
									, source.[blocking_client hostname]
									, source.report_xml
									, source.snapshot_time
									, source.snapshot_type_id)

						when matched and source.blocking_duration_ms > target.blocking_duration_ms then 
							update set
									  blocking_start_time = source.blocking_start_time --it may vary by few miliseconds
									, blocking_end_time = source.blocking_end_time
									, blocking_duration_ms = source.blocking_duration_ms
									, report_xml = source.report_xml
									, snapshot_time = @snapshot_time;

						--option (maxdop 1);
					commit tran

			end
	end
else
	print 'Product version must be 11 or higher'

